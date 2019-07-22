defmodule BlockScoutWeb.StakesController do
  use BlockScoutWeb, :controller

  alias BlockScoutWeb.StakesView
  alias Explorer.Chain
  alias Explorer.Chain.{BlockNumberCache, Wei}
  alias Explorer.Counters.AverageBlockTime
  alias Explorer.Staking.ContractState
  alias Phoenix.View

  import BlockScoutWeb.Chain, only: [paging_options: 1, next_page_params: 3, split_list_by_page: 1]

  def index(%{assigns: assigns} = conn, params) do
    render_template(assigns.filter, conn, params)
  end

  def render_top(conn) do
    epoch_number = ContractState.get(:epoch_number, 0)
    epoch_end_block = ContractState.get(:epoch_end_block, 0)
    block_number = BlockNumberCache.max_number()

    View.render_to_string(StakesView, "_stakes_top.html",
      epoch_number: epoch_number,
      epoch_end_in: epoch_end_block - block_number,
      block_number: block_number,
      account: delegator_info(conn.assigns[:account])
    )
  end

  defp render_template(filter, conn, %{"type" => "JSON"} = params) do
    [paging_options: options] = paging_options(params)

    last_index =
      params
      |> Map.get("position", "0")
      |> String.to_integer()

    pools_plus_one = Chain.staking_pools(filter, options)

    {pools, next_page} = split_list_by_page(pools_plus_one)

    next_page_path =
      case next_page_params(next_page, pools, params) do
        nil ->
          nil

        next_page_params ->
          updated_page_params =
            next_page_params
            |> Map.delete("type")
            |> Map.put("position", last_index + 1)

          next_page_path(filter, conn, updated_page_params)
      end

    average_block_time = AverageBlockTime.average_block_time()

    items =
      pools
      |> Enum.with_index(last_index + 1)
      |> Enum.map(fn {pool, index} ->
        View.render_to_string(
          StakesView,
          "_rows.html",
          pool: pool,
          index: index,
          average_block_time: average_block_time,
          pools_type: filter
        )
      end)

    json(
      conn,
      %{
        items: items,
        next_page_path: next_page_path
      }
    )
  end

  defp render_template(filter, conn, _) do
    render(conn, "index.html",
      top: render_top(conn),
      pools_type: filter,
      current_path: current_path(conn),
      average_block_time: AverageBlockTime.average_block_time()
    )
  end

  defp delegator_info(address) when not is_nil(address) do
    case Chain.delegator_info(address) do
      %{staked: staked, self_staked: self_staked, has_pool: has_pool} ->
        {:ok, staked_wei} = Wei.cast(staked || 0)
        {:ok, self_staked_wei} = Wei.cast(self_staked || 0)

        staked_sum = Wei.sum(staked_wei, self_staked_wei)
        stakes_token_name = System.get_env("STAKES_TOKEN_NAME") || "POSDAO"

        %{
          address: address,
          balance: get_token_balance(address, stakes_token_name),
          staked: staked_sum,
          has_pool: has_pool
        }

      _ ->
        {:ok, zero_wei} = Wei.cast(0)

        %{
          address: address,
          balance: zero_wei,
          staked: zero_wei,
          has_pool: false
        }
    end
  end

  defp delegator_info(_), do: nil

  defp get_token_balance(address, token_name) do
    {:ok, balance} =
      address
      |> Chain.address_tokens_with_balance()
      |> Enum.find_value(Wei.cast(0), fn token ->
        if token.name == token_name do
          Wei.cast(token.balance)
        end
      end)

    balance
  end

  defp next_page_path(:validator, conn, params) do
    validators_path(conn, :index, params)
  end

  defp next_page_path(:active, conn, params) do
    active_pools_path(conn, :index, params)
  end

  defp next_page_path(:inactive, conn, params) do
    inactive_pools_path(conn, :index, params)
  end
end
