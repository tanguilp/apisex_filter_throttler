defmodule APISexFilterThrottler do
  @behaviour Plug
  @behaviour APISex.Filter

  @moduledoc """
  An `APISex.Filter` plug for API requests rate-limiting

  This plug uses the [Exhammer](https://github.com/ExHammer/hammer) package as
  its backend. This library uses the token bucket algorithm, which means that
  this plug is mainly suitable for limiting abuses, not for accurate rate limiting. By
  default, a local ETS backend is launched on startup.

  ## Plug options

  - `key`: a
  `(Plug.Conn.t -> String.t | {String.t, non_neg_integer(), non_neg_integer()})`
  function, taking in parameter the connection and returning either the key, or the
  tuple `{key, scale, limit}`. No default value.
  Note that the `APISexFilterThrottler.Functions` provides with out-of-the-box functions
  - `scale`: the time window of the token bucket algorithm, in milliseconds. No default value.
  - `limit`: the maximum limit of the token bucket algorithm, in milliseconds. No default value.
  - `increment`: the increment of the token bucket algorithm (defaults to `1`)
  - `backend`: Exhammer's backend, defaults to `nil`
  - `set_filter_error_response`: if `true`, sets the HTTP status code to `429`.
  If false, does not do anything. Defaults to `true`
  - `halt_on_filter_failure`: if set to `true`, halts the connection and directly sends the
  response. When set to `false`, does nothing and therefore allows dealing with the error
  later in the code. Defaults to `true`

  ## Example

  Allow 50 request / 10 seconds per subject and per client:

  ```elixir
  Plug APISexFilterThrottler, key: &APISexFilterThrottler.Functions.throttle_by_subject_client/1,
    scale: 10_000,
    limit: 50
  ```

  Allow 5000 requests / minute per client

  ```elixir
  Plug APISexFilterThrottler, key: &APISexFilterThrottler.Functions.throttle_by_client/1,
    scale: 60_000,
    limit: 5000
  ```

  ## Security considerations

  Consider the risk of collisions when constructing the key> For instance, a key function
  concatenating the ip address and a subject (username) would return the same key
  ("72.23.241.121edwards") for:
  - a user "edwards" connecting from 72.23.241.121
  - a user "1edwards" connecting from 72.23.241.12

  The more control an attacker has on choosing the key parameters (e.g. the username), the
  easier to find a collision.

  Finding a collision can result in a DOS for the legitimate requester.

  Using a hash function such as `:erlang.phash2/1`, MD5, etc. cam help mitigate the risk,
  at the expense of performance. Also note that `:erlang.phash2/1` is not a
  collision-resistant hash function (as results are not uniformly distributed).

  """

  @impl Plug
  def init(opts) do
    if opts[:key] == nil, do: raise "`key` is a mandatory parameter"
    if opts[:scale] == nil, do: raise "`scale` is a mandatory parameter"
    if opts[:limit] == nil, do: raise "`limit` is a mandatory parameter"

    opts
    |> Enum.into(%{})
    |> Map.put_new(:increment, 1)
    |> Map.put_new(:backend, nil)
    |> Map.put_new(:set_filter_error_response, true)
    |> Map.put_new(:halt_on_filter_failure, true)
  end

  @impl Plug
  def call(conn, opts) do
    case filter(conn, opts) do
      {:ok, conn} ->
        conn

      {:error, conn, reason} ->
        conn =
          if opts[:set_filter_error_response] do
            set_error_response(conn, reason, opts)
          else
            conn
          end

        if opts[:halt_on_filter_failure] do
          conn
          |> Plug.Conn.send_resp()
          |> Plug.Conn.halt()
        else
          conn
        end
    end
  end

  @impl APISex.Filter
  def filter(conn, opts) do
    {key, scale, limit} =
      case get_filter_fun(opts[:key]).(conn) do
        key when is_binary(key) ->
          {key, opts[:scale], opts[:limit]}

        {key, scale, limit} ->
          {key, scale, limit}
      end

    case throttle(opts[:backend], key, scale, limit, opts[:increment]) do
      {:allow, _count} ->
        {:ok, conn}

      {:deny, _limit} ->
        {:ok, {_count, _count_remaining, ms_to_next_bucket, _created_at, _updated_at}} =
          Hammer.inspect_bucket(key, scale, limit)

        {:error, conn, %APISex.Filter.Forbidden{filter: __MODULE__,
                                                reason: :rate_limited,
                                                error_data: ms_to_next_bucket}}

      {:error, reason} ->
        {:error, conn, %APISex.Filter.Forbidden{filter: __MODULE__, reason: reason}}
    end
  end

  defp get_filter_fun(fun) when is_function(fun, 1), do: fun
  defp get_filter_fun(params) when is_list(params)
  do
    function_name = "throttle_" <>
      (
        params
        |> Enum.sort()
        |> Enum.map(&Atom.to_string/1)
        |> Enum.join("_")
      )

    Module.concat(APISexFilterThrottler.Functions, function_name)
  end

  defp throttle(nil, key, scale, limit, increment) do
    Hammer.check_rate_inc(key, scale, limit, increment)
  end

  defp throttle(backend, key, scale, limit, increment) do
    Hammer.check_rate_inc(backend, key, scale, limit, increment)
  end

  @impl APISex.Filter
  def set_error_response(conn, %APISex.Filter.Forbidden{error_data: ms_to_next_bucket}, _opts) do
    retry_after = Integer.to_string(trunc(ms_to_next_bucket / 1000) + 1)
    conn
    |> Plug.Conn.put_resp_header("retry-after", retry_after)
    |> Plug.Conn.resp(:too_many_requests, "")
  end
end
