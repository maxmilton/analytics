defmodule Plausible.Billing.PlansTest do
  use Plausible.DataCase, async: true
  use Plausible.Teams.Test
  alias Plausible.Billing.Plans

  @legacy_plan_id "558746"
  @v1_plan_id "558018"
  @v2_plan_id "654177"
  @v3_business_plan_id "857481"

  describe "getting subscription plans for user" do
    test "growth_plans_for/1 returns v1 plans for a user on a legacy plan" do
      new_user()
      |> subscribe_to_plan(@legacy_plan_id)
      |> Map.fetch!(:subscription)
      |> Plans.growth_plans_for()
      |> assert_generation(1)
    end

    test "growth_plans_for/1 returns v1 plans for users who are already on v1 pricing" do
      new_user()
      |> subscribe_to_plan(@v1_plan_id)
      |> Map.fetch!(:subscription)
      |> Plans.growth_plans_for()
      |> assert_generation(1)
    end

    test "growth_plans_for/1 returns v2 plans for users who are already on v2 pricing" do
      new_user()
      |> subscribe_to_plan(@v2_plan_id)
      |> Map.fetch!(:subscription)
      |> Plans.growth_plans_for()
      |> assert_generation(2)
    end

    test "growth_plans_for/1 returns v4 plans for expired legacy subscriptions" do
      new_user()
      |> subscribe_to_plan(@v1_plan_id, status: :deleted, next_bill_date: ~D[2023-11-10])
      |> Map.fetch!(:subscription)
      |> Plans.growth_plans_for()
      |> assert_generation(4)
    end

    test "growth_plans_for/1 shows v4 plans for everyone else" do
      new_user()
      |> Repo.preload(:subscription)
      |> Map.fetch!(:subscription)
      |> Plans.growth_plans_for()
      |> assert_generation(4)
    end

    test "growth_plans_for/1 does not return business plans" do
      new_user()
      |> Repo.preload(:subscription)
      |> Map.fetch!(:subscription)
      |> Plans.growth_plans_for()
      |> Enum.each(fn plan ->
        assert plan.kind != :business
      end)
    end

    test "growth_plans_for/1 returns the latest generation of growth plans for a user with a business subscription" do
      new_user()
      |> subscribe_to_plan(@v3_business_plan_id)
      |> Map.fetch!(:subscription)
      |> Plans.growth_plans_for()
      |> assert_generation(4)
    end

    test "business_plans_for/1 returns v3 business plans for a user on a legacy plan" do
      new_user()
      |> subscribe_to_plan(@legacy_plan_id)
      |> Map.fetch!(:subscription)
      |> Plans.business_plans_for()
      |> assert_generation(3)
    end

    test "business_plans_for/1 returns v3 business plans for a v2 subscriber" do
      user = new_user() |> subscribe_to_plan(@v2_plan_id)

      business_plans = Plans.business_plans_for(user.subscription)

      assert Enum.all?(business_plans, &(&1.kind == :business))
      assert_generation(business_plans, 3)
    end

    test "business_plans_for/1 returns v4 plans for invited users with trial_expiry = nil" do
      new_user(trial_expiry_date: nil)
      |> Repo.preload(:subscription)
      |> Map.fetch!(:subscription)
      |> Plans.business_plans_for()
      |> assert_generation(4)
    end

    test "business_plans_for/1 returns v4 plans for expired legacy subscriptions" do
      user =
        new_user()
        |> subscribe_to_plan(@v2_plan_id, status: :deleted, next_bill_date: ~D[2023-11-10])

      user.subscription
      |> Plans.business_plans_for()
      |> assert_generation(4)
    end

    test "business_plans_for/1 returns v4 business plans for everyone else" do
      user = new_user() |> Repo.preload(:subscription)
      business_plans = Plans.business_plans_for(user.subscription)

      assert Enum.all?(business_plans, &(&1.kind == :business))
      assert_generation(business_plans, 4)
    end

    test "available_plans returns all plans for user with prices when asked for" do
      user = new_user() |> subscribe_to_plan(@v2_plan_id)

      %{growth: growth_plans, business: business_plans} =
        Plans.available_plans_for(user.subscription, with_prices: true, customer_ip: "127.0.0.1")

      assert Enum.find(growth_plans, fn plan ->
               (%Money{} = plan.monthly_cost) && plan.monthly_product_id == @v2_plan_id
             end)

      assert Enum.find(business_plans, fn plan ->
               (%Money{} = plan.monthly_cost) && plan.monthly_product_id == @v3_business_plan_id
             end)
    end

    test "available_plans returns all plans without prices by default" do
      user = new_user() |> subscribe_to_plan(@v2_plan_id)

      assert %{growth: [_ | _], business: [_ | _]} = Plans.available_plans_for(user.subscription)
    end

    test "latest_enterprise_plan_with_price/1" do
      user = insert(:user)
      insert(:enterprise_plan, user: user, paddle_plan_id: "123", inserted_at: Timex.now())

      insert(:enterprise_plan,
        user: user,
        paddle_plan_id: "456",
        inserted_at: Timex.shift(Timex.now(), hours: -10)
      )

      insert(:enterprise_plan,
        user: user,
        paddle_plan_id: "789",
        inserted_at: Timex.shift(Timex.now(), minutes: -2)
      )

      {enterprise_plan, price} = Plans.latest_enterprise_plan_with_price(user, "127.0.0.1")

      assert enterprise_plan.paddle_plan_id == "123"
      assert price == Money.new(:EUR, "10.0")
    end
  end

  describe "subscription_interval" do
    test "is based on the plan if user is on a standard plan" do
      user = insert(:user, subscription: build(:subscription, paddle_plan_id: @v1_plan_id))

      assert Plans.subscription_interval(user.subscription) == "monthly"
    end

    test "is N/A for free plan" do
      user = insert(:user, subscription: build(:subscription, paddle_plan_id: "free_10k"))

      assert Plans.subscription_interval(user.subscription) == "N/A"
    end

    test "is based on the enterprise plan if user is on an enterprise plan" do
      user = insert(:user)

      enterprise_plan = insert(:enterprise_plan, user_id: user.id, billing_interval: :yearly)

      subscription =
        insert(:subscription, user_id: user.id, paddle_plan_id: enterprise_plan.paddle_plan_id)

      assert Plans.subscription_interval(subscription) == :yearly
    end
  end

  describe "suggested_plan/2" do
    test "returns suggested plan based on usage" do
      user = new_user() |> subscribe_to_plan(@v1_plan_id)

      assert %Plausible.Billing.Plan{
               monthly_pageview_limit: 100_000,
               monthly_cost: nil,
               monthly_product_id: "558745",
               volume: "100k",
               yearly_cost: nil,
               yearly_product_id: "590752"
             } = Plans.suggest(user, 10_000)

      assert %Plausible.Billing.Plan{
               monthly_pageview_limit: 200_000,
               monthly_cost: nil,
               monthly_product_id: "597485",
               volume: "200k",
               yearly_cost: nil,
               yearly_product_id: "597486"
             } = Plans.suggest(user, 100_000)
    end

    test "returns nil when user has enterprise-level usage" do
      user = new_user() |> subscribe_to_plan(@v1_plan_id)
      assert :enterprise == Plans.suggest(user, 100_000_000)
    end

    test "returns nil when user is on an enterprise plan" do
      user =
        new_user()
        |> subscribe_to_plan(@v1_plan_id)
        |> subscribe_to_enterprise_plan(billing_interval: :yearly, subscription?: false)

      assert :enterprise == Plans.suggest(user, 10_000)
    end
  end

  describe "yearly_product_ids/0" do
    test "lists yearly plan ids" do
      assert [
               "590753",
               "648089",
               "572810",
               "590752",
               "597486",
               "597488",
               "597643",
               "597310",
               "597312",
               "642354",
               "642356",
               "650653",
               "653232",
               "653234",
               "653236",
               "653239",
               "653242",
               "653254",
               "653256",
               "653257",
               "653258",
               "653259",
               "749343",
               "749345",
               "749347",
               "749349",
               "749352",
               "749355",
               "749357",
               "749359",
               "857482",
               "857484",
               "857487",
               "857491",
               "857494",
               "857496",
               "857500",
               "857502",
               "857079",
               "857080",
               "857081",
               "857082",
               "857083",
               "857084",
               "857085",
               "857086",
               "857087",
               "857088",
               "857089",
               "857090",
               "857091",
               "857092",
               "857093",
               "857094"
             ] == Plans.yearly_product_ids()
    end
  end

  defp assert_generation(plans_list, generation) do
    assert List.first(plans_list).generation == generation
  end
end
