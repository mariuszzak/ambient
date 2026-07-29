# Only compiled when Credo is available (it's an optional dependency).
if Code.ensure_loaded?(Credo.Check) do
  defmodule Ambient.Credo.NoDirectConfig do
    @moduledoc """
    Bans direct **runtime** reads of your own application's config, so they
    can't bypass the `Ambient.Config` per-process override layer. Route them
    through your `use Ambient.Config` module instead.

    Parameterized – a library can't know your app name or Config module:

        {Ambient.Credo.NoDirectConfig, otp_app: :my_app, replacement: "MyApp.Config"}

    With no `:otp_app` configured the check is a no-op.

    Flags `Application.get_env/{2,3}`, `fetch_env/2`, `fetch_env!/2` (and the
    Erlang `:application` equivalents) whose first argument is the configured
    `:otp_app`. Ignores other apps' config, `compile_env/*`, and `put_env/*`.
    """

    use Credo.Check,
      base_priority: :normal,
      category: :warning,
      param_defaults: [otp_app: nil, replacement: nil, exempt_suffixes: []],
      explanations: [
        check: """
        Direct runtime reads of your own app's config bypass the
        `Ambient.Config` override layer and can't be set per-process in
        `async: true` tests. Route through your Config module instead.
        """,
        params: [
          otp_app: "The OTP application whose config reads should be routed (required).",
          replacement: "Your Config module name, shown in the message (e.g. \"MyApp.Config\").",
          exempt_suffixes: "File path suffixes exempt from the check."
        ]
      ]

    alias Ambient.Credo.MFAScanner
    alias Credo.Check.Params

    @banned_funs [:get_env, :fetch_env, :fetch_env!]

    @impl true
    def run(%SourceFile{} = source_file, params \\ []) do
      otp_app = Params.get(params, :otp_app, __MODULE__)

      if is_nil(otp_app) or
           MFAScanner.exempt?(source_file, Params.get(params, :exempt_suffixes, __MODULE__)) do
        []
      else
        replacement = Params.get(params, :replacement, __MODULE__) || "your Config module"
        issue_meta = IssueMeta.for(source_file, params)
        Credo.Code.prewalk(source_file, &traverse(&1, &2, {issue_meta, otp_app, replacement}))
      end
    end

    # A pipe hides the first argument, so `:my_app |> Application.get_env(:k)`
    # has no `app` to match on. `prewalk` never re-applies this function to what
    # we return, only to its children, so match the outermost call here.
    defp traverse({:|>, _, [_, _]} = ast, issues, ctx) do
      traverse(MFAScanner.unpipe(ast), issues, ctx)
    end

    defp traverse(
           {{:., _, [{:__aliases__, meta, [:Application]}, fun]}, _, [app | _] = args} = ast,
           issues,
           ctx
         )
         when fun in @banned_funs and is_list(args) do
      {ast, maybe_issue(issues, ctx, meta, fun, app)}
    end

    defp traverse(
           {{:., meta, [:application, fun]}, _, [app | _] = args} = ast,
           issues,
           ctx
         )
         when fun in @banned_funs and is_list(args) do
      {ast, maybe_issue(issues, ctx, meta, fun, app)}
    end

    defp traverse(ast, issues, _ctx), do: {ast, issues}

    defp maybe_issue(issues, {issue_meta, otp_app, replacement}, meta, fun, app)
         when app == otp_app do
      banned = "Application.#{fun}(#{inspect(otp_app)}, …)"

      issue =
        format_issue(issue_meta,
          message:
            "#{banned} bypasses #{replacement} – its per-process override layer won't apply. " <>
              "Use #{replacement}.get/2 instead.",
          trigger: "Application.#{fun}",
          line_no: meta[:line]
        )

      [issue | issues]
    end

    defp maybe_issue(issues, _ctx, _meta, _fun, _app), do: issues
  end
end
