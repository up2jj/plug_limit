defmodule PlugLimit do
  @moduledoc """
  Rate limiting Plug module based on Redis Lua scripting.

  ## Architecture
  `PlugLimit` is a `Plug` behaviour module implementation using
  [Redis Lua scripting](https://redis.io/docs/manual/programmability/eval-intro/) to provide
  rate limiting functionality.
  Module plugs should implement two callback functions: `c:Plug.init/1` and `c:Plug.call/2`.
  `PlugLimit` `init/1` function is responsible for building plug configuration, please refer to the
  [Configuration](#module-configuration) section below for details.

  `PlugLimit` `call/2` function has following responsibilities:
  1. Establish if given request should be allowed or denied in accordance with selected rate
     limiting strategy.
  2. Determine values of the rate limiting http headers.
  3. Set rate limiting http headers for the response.
  4. Halt request processing pipeline if rate limit was exceeded and send response with
     appropriate status code, usually `429 - Too Many Requests`.

  Tasks 1 and 2 are performed by evaluation of the Redis Lua script implementing rate limiting
  algorithm.
  Tasks 3 and 4 are executed by built-in `put_response/4` function or user provided equivalent
  callback function leveraging Redis Lua script evaluation results.

  PlugLimit Redis Lua scripts are loaded to the Redis scripts cache on the first `c:Plug.call/2`
  callback invocation by using Redis [`SCRIPT LOAD`](https://redis.io/commands/script-load/)
  command.
  Generated by `SCRIPT LOAD` SHA1 script hash is cached locally as a `:persistent_term` key.
  Lua script SHA1 hash is later retrieved from `:persistent_term` local cache and used with
  Redis [`EVALSHA`](https://redis.io/commands/evalsha/) command on subsequent rate-limiter
  Lua script evaluations.
  Implemented SHA1 Lua script caching mechanism is resilient to Redis script cache resets by Redis
  instance reboots or Redis [`SCRIPT FLUSH`](https://redis.io/commands/script-flush/) command use.

  Redis Lua script evaluation is an atomic operation resilient to the race conditions in distributed
  environments.

  In normal circumstances latency introduced by Redis `EVALSHA` command should be close to a single
  Redis request/response round trip time, usually less than ~1 ms.

  Redis Lua script execution blocks single-threaded Redis server, so it is advised to use a separate
  standalone Redis instance for PlugLimit rate-limiters, especially when using custom untested
  Lua script implementations.
  Data stored by Redis rate-limiters in most cases can be considered as strongly interim so
  using highly available Redis Sentinel instances for rate-limiters data might be unnecessary.
  For high traffic volume cases, sharding can be easily achieved by distributing independent Phoenix
  router pipelines or scopes rate-limiters between dedicated Redis instances.

  ## Usage
  PlugLimit in most basic use case requires configuration of a function which will execute Redis
  commands:
  ```elixir
  # config/config.exs
  config :plug_limit,
    enabled?: true,
    cmd: {MyApp.Redis, :command, []}
  ```

  When working with Phoenix Framework `PlugLimit` plug call can be placed at the endpoint, router
  or controller depending on requirements.
  Example of minimal `PlugLimit` call used in `:high_cost_pipeline` router pipeline:
  ```elixir
  #lib/my_app_web/router.ex
  pipeline :high_cost_pipeline do
    plug(PlugLimit, opts: [10, 60], key: {MyApp.RateLimiter, :user_id_key, [:high_cost_pipeline]})
    # remaining pipeline plugs...
  end
  ```

  Example above will evaluate request rate-limiting parameters using built-in default Lua script
  implementing fixed window algorithm with rate limiter algorithm options given in the `:opts` list.
  First list element specifies request limit, set to 10 here, second item specifies limiting time
  window length in seconds, set to 60.
  Redis rate-limiter bucket name will be evaluated with function defined by the `:key` MFA tuple.
  Example Redis key bucket name function result for `user_id=12345`:
  `{:ok, ["high_cost_pipeline_limiter:12345"]}`.

  Example `PlugLimit` configuration for built-in token bucket rate-limiter:
  ```elixir
  #lib/my_app_web/router.ex
  pipeline :high_cost_pipeline do
    plug(PlugLimit,
      limiter: :token_bucket,
      opts: [20, 600, 5],
      key: {MyApp.RateLimiter, :user_id_key, ["high_cost_pipeline"]}
    )
    # remaining pipeline plugs...
  end
  ```

  Configuration options details are described in the [Configuration](#module-configuration)
  section below.

  Instead of using generic `PlugLimit` module you can use provided convenience wrappers:
  `PlugLimit.FixedWindow` or `PlugLimit.TokenBucket`.

  Built-in rate-limiting algorithms are described in the "Redis Lua script rate limiters"
  LIMITERS.md file.

  Unit testing for user applications using PlugLimit library is described in "Unit testing"
  TESTING.md file.

  ## Configuration
  PlugLimit configuration is built from following sources:
  * global `:plug_limit` configuration parameters from application configuration file, usually
    `config/*.exs`,
  * parameters overwriting global configuration passed as arguments to the PlugLimit plug
    call in the application router or controller,
  * hard-coded default values.

  `PlugLimit` is using a concept of rate-limiters to organize individual limiters configurations.
  Rate-limiters configurations are declared in application configuration file using `:limiters`
  key. Each rate-limiter must be associated with a valid Lua script. Lua scripts are configured
  with `:luascripts` key.

  Full example configuration defining `:custom_limiter` limiter using `:custom_bucket` Lua script:
  ```elixir
  # config/config.exs
  config :plug_limit,
    limiters: [
      custom_limiter: %{
        cmd: {MyApp.Redis, :command, ["redis://10.10.10.2:6379/"]},
        key: {MyApp.RateLimiter, :user_id_key, []},
        log_level: :error,
        luascript: :custom_bucket,
        response: {MyApp.RateLimiter, :respond, []}
      }
    ],
    luascripts: [
      custom_bucket: %{
        script: {File, :read, ["./lua/custom_bucket.lua"]},
        headers: [
          "x-ratelimit-limit",
          "x-ratelimit-reset",
          "x-ratelimit-remaining",
          "x-acme-custom-header"
        ]
      }
    ]
  ```
  Above defined `:custom_limiter` should be referred as follows:
  ```elixir
  plug(PlugLimit, limiter: :custom_limiter, opts: [20, 600, 5])
  ```

  ### Application configuration options
  Primary part of `PlugLimit` configuration is located in the application configuration file,
  usually `config/config.exs`, under `:plug_limit` key. Some of the options defined in application
  configuration can be overwritten with `plug(PlugLimit, [options...])` call.

  Available configuration options:
  * `:enabled?` - when set to Boolean `false` or string `"false"` `PlugLimit` is disabled and
    `plug(PlugLimit, opts: [...])` call immediately returns unmodified `conn` struct.
    To enable `PlugLimit`, `:enabled?` key must be set to Boolean `true` or string `"true"`.
    Default: `false`.
  * `:cmd` - MFA tuple pointing at the user defined two arity function executing Redis commands.
    As a first argument function will receive a Redis command as a list, for example:
    `["SET", "mykey", "foo"]`.
    As a second parameter, static argument defined in the MFA tuple will be passed.
    Redis command function should return `{:ok, redis_response}` on success and `{:error, reason}`
    on error.
    When using [Redix](https://hex.pm/packages/redix) library as a client, `:cmd` command should be
    a `Redix.command/3` wrapper.
    When using [eredis](https://hex.pm/packages/eredis) library, wrapper for the `:eredis.q/2,3`
    should be implemented.
    Redis command function defined here will be used as a default function for limiters that
    do not have their own `:cmd` specified.
    Optional if each limiter has its own `:cmd` defined, required otherwise.
  * `:log_level` - specifies log level for rate-limiters that do not set their own `:log_level`.
    Only library errors are logged - with `put_response/4` function.
    Boolean value `false` disables logging. Please refer to the `Logger` documentation
    for valid log levels. Default: `:error`.
  * `:response` - MFA tuple pointing at the user defined 4 arity function providing request
    response depending on rate-limiter Lua script evaluation results.
    Please refer to the built-in response function `put_response/4` description for details.
    Can be overwritten for individual limiters.
    Default: `put_response/4`.
  * `:limiters` - keyword list with user provided rate-limiters. See below for details. Optional.
  * `:luascripts` - keyword list defining Lua scripts for rate-limiters defined with `:limiters`.
    See below for details. Optional.

  PlugLimit `:enabled?` option is the only option evaluated at run-time with `c:Plug.call/2`,
  so function like `System.get_env/2` can be used here.
  All other configuration options are initialized with `c:Plug.init/1`, which usually takes place at
  compile time for production or release environments and run-time for testing and development.
  In a production environment, `PlugLimit` `:enabled` might be controlled using environmental
  variable, for example:
  ```elixir
  # config/config.exs
  config :plug_limit, cmd: {MyApp.Redis, :command, []}

  # config/releases.exs
  config :plug_limit, enabled?: System.get_env("PLUG_LIMIT_ENABLED", "false")

  # config/dev.exs
  config :plug_limit, enabled?: true

  # config/test.exs
  config :plug_limit, enabled?: true
  ```

  Custom user rate-limiters are configured as a `:limiters` keyword list.
  Rate-limiters are declared as maps with following keys:
  * `:cmd` - overwrites `:cmd` global key for a given rate-limiter. Optional.
  * `:key` - MFA tuple pointing at the user defined two arity function providing Redis keys names
    that will be passed later to the Redis Lua script.
    Function receives request `Plug.Conn.t()` struct as a first argument and static argument from
    the MFA tuple as a second argument.
    Function should return `{:ok, [key :: String.t()]}` when successful and `{:error, reason}`
    on error. Function should return especially name of the key that Redis Lua script will use to
    create a unique bucket for a given rate-limiter and requests group.
    Please refer to "Redis Lua script rate limiters" LIMITERS.md file for further discussion.
    Example `:key` function implementation:
    ```elixir
    def user_key(%Plug.Conn{assigns: %{user_id: user_id}}, prefix),
      do: {:ok, [to_string(prefix) <> ":" <> to_string(user_id)]}

    def user_key(_conn, _prefix), do: {:error, "Missing user_id"}
    ```
    Redis keys names should follow
    [Redis keys naming conventions](https://redis.io/docs/manual/data-types/data-types-tutorial/#keys).
    `:key` value can be overwritten in a plug call configuration.
    Optional if `:key` is specified for each `PlugLimit` plug call, required otherwise.
  * `:log_level` - overwrites global `:log_level` for a given rate-limiter. Optional.
  * `:luascript` - atom defining Lua script for a given rate-limiter. Lua scripts are defined with
    `:luascripts` keyword list, see below for details. Required.
  * `:response` - overwrites global `:response` for a given rate-limiter. Optional.

  PlugLimit provides two built-in rate-limiters: `:fixed_window` and `:token_bucket`, please refer
  to "Redis Lua script rate limiters" LIMITERS.md file for details.

  Each rate-limiter is associated with Redis Lua script checking if given request should
  be allowed or denied and evaluating rate limiting http headers. Redis Lua scripts are configured
  as `:luascripts` keyword list. Each script is declared as a map with following keys:
  * `:script` - MFA tuple pointing at one arity function returning
    `{:ok, limiter_script :: String.t()}` on success and `{:error, reason}` on error.
    Function receives as an argument static argument from the MFA tuple.
    Example implementations:
    ```elixir
    def get_lua_script_by_path(path), do: File.read(path)

    def my_lua_script(_arg), do: {:ok, "-- Lua script body"}
    ```
    Required.
  * `:headers` - list of rate limiting headers keys to be used with headers values returned by
    given Redis Lua script to build request response http headers.
    Example headers list:
    ```elixir
    headers: [
      "x-ratelimit-limit",
      "x-ratelimit-reset",
      "x-ratelimit-remaining"
    ]
    ```
    Please refer to "Redis Lua script rate limiters" LIMITERS.md file for more detailed discussion
    on rate limiting headers. Required.

  ### Plug call configuration options
  * `:key` - MFA tuple, overwrites value given in limiter's application configuration.
    Required if not provided in the limiter configuration.
  * `:limiter` - atom selecting rate limiter. List of built-in limiters is provided in LIMITERS.md
    file. Default: `:fixed_window`.
  * `:opts` - list with rate limiting options like requests limit, time window length or burst rate.
    List is passed as an argument to the Redis Lua script, see LIMITERS.md for built-in limiters
    options. Required.
  """

  @behaviour Plug
  import Plug.Conn
  require Logger

  @default_limiter_id :fixed_window

  @default_limiters [
    fixed_window: %{
      luascript: :fixed_window
    },
    token_bucket: %{
      luascript: :token_bucket
    }
  ]

  @default_luascripts [
    fixed_window: %{
      script: {__MODULE__, :get_script, [:fixed_window]},
      headers: [
        "x-ratelimit-limit",
        "x-ratelimit-reset",
        "x-ratelimit-remaining"
      ]
    },
    token_bucket: %{
      script: {__MODULE__, :get_script, [:token_bucket]},
      headers: [
        "x-ratelimit-limit",
        "x-ratelimit-reset",
        "x-ratelimit-remaining",
        "retry-after"
      ]
    }
  ]

  @default_log_level :error

  @default_response {__MODULE__, :put_response, []}

  @default_script_fixed_window File.read("./lua/fixed_window.lua")
  @default_script_token_bucket File.read("./lua/token_bucket.lua")

  @limit_status 429
  @limit_body "Too Many Requests"

  @no_script_msg ["NOSCRIPT No matching script. Please use EVAL."]

  defstruct [
    :cmd,
    :headers,
    :key,
    :log_level,
    :opts,
    :response,
    :script,
    :script_id
  ]

  @type t() :: %__MODULE__{
          cmd: mfa(),
          headers: [String.t()],
          key: mfa(),
          log_level: log_level(),
          opts: list(),
          response: mfa(),
          script: mfa(),
          script_id: atom()
        }
  @type limiters :: [
          {limiter_id :: atom, limiter :: limiter()}
        ]
  @type limiter :: %{
          cmd: mfa(),
          key: mfa(),
          log_level: log_level(),
          luascript: atom(),
          response: mfa()
        }
  @type luascripts :: [
          {luascript_id :: atom(), luascript :: luascript()}
        ]
  @type luascript :: %{
          headers: [String.t()],
          opts: list(),
          script: mfa()
        }
  @type log_level :: false | Logger.level()

  @type eval_result :: {:ok, list()} | {:error, any()} | any()

  @impl true
  @doc false
  @spec init(opts :: Plug.opts()) :: PlugLimit.t()
  def init(opts) do
    limiters = Application.get_env(:plug_limit, :limiters, @default_limiters)
    luascripts = Application.get_env(:plug_limit, :luascripts, @default_luascripts)

    limiter_id = Keyword.get(opts, :limiter, @default_limiter_id)
    limiter = Keyword.get(limiters, limiter_id) || Keyword.fetch!(@default_limiters, limiter_id)
    script_id = Map.fetch!(limiter, :luascript)
    key = Keyword.get(opts, :key) || Map.fetch!(limiter, :key)

    luascript =
      Keyword.get(luascripts, script_id) || Keyword.fetch!(@default_luascripts, script_id)

    script = Map.fetch!(luascript, :script)
    headers = Map.fetch!(luascript, :headers)
    l_opts = Keyword.fetch!(opts, :opts)

    cmd = Map.get(limiter, :cmd) || Application.fetch_env!(:plug_limit, :cmd)

    log_level =
      Map.get(limiter, :log_level) ||
        Application.get_env(:plug_limit, :log_level, @default_log_level)

    response =
      Map.get(limiter, :response) ||
        Application.get_env(:plug_limit, :response, @default_response)

    opts = %{
      cmd: cmd,
      headers: headers,
      key: key,
      log_level: log_level,
      opts: l_opts,
      response: response,
      script: script,
      script_id: script_id
    }

    struct!(__MODULE__, opts)
  end

  @impl true
  @doc false
  @spec call(conn :: Plug.Conn.t(), conf :: Plug.opts()) :: Plug.Conn.t()
  def call(conn, conf) do
    case Application.get_env(:plug_limit, :enabled?, false) do
      res when res in ["true", true] ->
        eval_result = eval_limit(conn, conf)
        apply_response(conn, conf, eval_result)

      res when res in ["false", false] ->
        conn
    end
  end

  @doc """
  Puts new rate limiting http response headers in the connection and halts the Plug pipeline if
  rate limit was exceeded.

  `put_response/4` is a default `PlugLimit` function preparing an http response accordingly
  with Redis Lua script evaluation results.
  Custom response function can be selected by setting `:response` global or given limiter
  configuration keys.

  Function accepts following arguments:
  1. `Plug.Conn.t()` connection.
  2. Rate-limiter configuration as a `PlugLimit.t()` struct.
  3. Redis Lua script evaluation result as a `PlugLimit.eval_result()` type.
  4. Static argument given in the `:response` MFA tuple.

  Function returns `Plug.Conn.t()` struct with rate limiting headers.
  If rate limit is exceeded function halts Plug pipeline and sends response with `429` status code
  and plain-text body `"Too Many Requests"`.
  If Redis Lua script evaluation or any other rate-limiting processing function fails,
  `put_response/4` function will log resulting error with Logger level set by `:log_level`
  configuration setting and return unmodified connection struct.

  Custom response functions and custom Redis Lua scripts are described in more details in
  "Redis Lua script rate limiters" LIMITERS.md file.
  """
  @spec put_response(
          conn :: Plug.Conn.t(),
          conf :: PlugLimit.t(),
          eval_result :: eval_result(),
          args :: any()
        ) :: Plug.Conn.t()
  def put_response(conn, %__MODULE__{} = conf, eval_result, _args) do
    case eval_result do
      {:ok, [action, headers | _other]} ->
        conn = put_headers(conn, headers, conf.headers)

        if action == "allow" do
          conn
        else
          conn
          |> put_resp_content_type("text/plain")
          |> send_resp(@limit_status, @limit_body)
          |> halt()
        end

      err ->
        log_level = Map.fetch!(conf, :log_level)
        if log_level, do: Logger.log(log_level, "[#{__MODULE__}] #{inspect(err)}")
        conn
    end
  end

  @doc false
  def get_script(:fixed_window), do: @default_script_fixed_window
  def get_script(:token_bucket), do: @default_script_token_bucket

  @spec eval_limit(Plug.Conn.t(), PlugLimit.t()) :: eval_result()
  defp eval_limit(conn, %__MODULE__{opts: lua_opts} = conf) do
    with {:ok, sha} <- get_sha(conf),
         {:ok, key} <- get_key(conn, conf),
         command <- ["EVALSHA", sha, length(key)] ++ key ++ lua_opts,
         {:ok, result} <- apply_command(conf, [command]) do
      {:ok, result}
    else
      {:error, msg} ->
        with true <- noscript_error?(msg),
             {:ok, sha} <- load_sha(conf),
             {:ok, key} <- get_key(conn, conf) do
          command = ["EVALSHA", sha, length(key)] ++ key ++ lua_opts
          apply_command(conf, [command])
        else
          false -> {:error, msg}
          err -> err
        end

      err ->
        err
    end
  end

  defp put_headers(conn, [[header_k, header_v] | headers_t], [_d_h_k | d_h_t]) do
    conn
    |> put_resp_header(header_k, header_v)
    |> put_headers(headers_t, d_h_t)
  end

  defp put_headers(conn, [header_v | headers_t], [d_h_k | d_h_t]) do
    conn
    |> put_resp_header(d_h_k, header_v)
    |> put_headers(headers_t, d_h_t)
  end

  defp put_headers(conn, [[header_k, header_v] | headers_t], []) do
    conn
    |> put_resp_header(header_k, header_v)
    |> put_headers(headers_t, [])
  end

  defp put_headers(conn, [], _default_headers), do: conn

  defp get_sha(%__MODULE__{script_id: script_id} = conf) do
    case :persistent_term.get({__MODULE__, :sha, script_id}, nil) do
      nil -> load_sha(conf)
      sha -> {:ok, sha}
    end
  end

  defp load_sha(%__MODULE__{script: {m, f, a}, script_id: id} = conf) do
    with {:ok, script} <- apply(m, f, a),
         command <- ["SCRIPT", "LOAD", script],
         {:ok, sha} <- apply_command(conf, [command]),
         :ok <- :persistent_term.put({__MODULE__, :sha, id}, sha) do
      {:ok, sha}
    else
      err ->
        :persistent_term.erase(id)
        err
    end
  end

  defp get_key(conn, %__MODULE__{key: {m, f, a}}), do: apply(m, f, [conn, a])

  defp apply_command(%__MODULE__{cmd: {m, f, a}}, command), do: apply(m, f, command ++ a)

  defp apply_response(conn, %__MODULE__{response: {m, f, a}} = conf, eval_result),
    do: apply(m, f, [conn, conf, eval_result, a])

  defp noscript_error?(msg) when is_map(msg) or is_struct(msg),
    do: msg |> Map.get(:message, "") |> noscript_error?()

  defp noscript_error?(msg), do: msg in @no_script_msg
end
