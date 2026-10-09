# This file contains the configuration for Credo and you are probably reading
# this after creating it with `mix credo.gen.config`.
#
# If you find anything wrong or unclear in this file, please report an
# issue on GitHub: https://github.com/rrrene/credo/issues
#
# Baseline of pre-existing findings (introduced with CI, issue #54).
#
# These files are being changed by several in-flight PRs (#79-#88). Fixing
# purely stylistic findings in them now would only produce merge conflicts,
# so they are excluded per check below. New files get the full strict rule
# set. When you touch a file listed here, fix its finding and drop the entry.
baseline_alias_order = [
  "lib/converger/activities.ex",
  "lib/converger/channels.ex",
  "lib/converger/conversations.ex",
  "lib/converger/deliveries.ex",
  "lib/converger/pipeline.ex",
  "lib/converger/tenants.ex",
  "lib/converger/workers/conversation_expiration_worker.ex",
  "lib/converger_web/channels/conversation_channel.ex",
  "lib/converger_web/controllers/converger/conversation_controller.ex",
  "lib/converger_web/controllers/conversation_controller.ex",
  "lib/converger_web/controllers/inbound_controller.ex",
  "lib/converger_web/controllers/token_controller.ex",
  "lib/converger_web/live/admin/channel_live.ex",
  "lib/converger_web/live/portal/conversation_live.ex",
  "test/converger/audit_logs_integration_test.exs",
  "test/converger/workers/conversation_expiration_worker_test.exs",
  "test/converger_web/channels/conversation_channel_test.exs",
  "test/converger_web/live/admin_crud_test.exs"
]

baseline_module_doc = [
  "lib/converger/auth/converger_token.ex",
  "lib/converger/channels/adapters/webhook.ex",
  "lib/converger/channels/adapters/whatsapp_infobip.ex",
  "lib/converger/channels/adapters/whatsapp_meta.ex",
  "lib/converger/workers/activity_delivery_worker.ex",
  "lib/converger/workers/conversation_expiration_worker.ex",
  "lib/converger_web/channels/converger_channel.ex",
  "lib/converger_web/channels/conversation_channel.ex",
  "lib/converger_web/plugs/converger_auth.ex",
  "lib/converger_web/plugs/rate_limit.ex"
]

baseline_alias_usage = [
  "lib/converger/auth/converger_token.ex",
  "lib/converger/channels/channel.ex"
]

%{
  #
  # You can have as many configs as you like in the `configs:` field.
  configs: [
    %{
      #
      # Run any config using `mix credo -C <name>`. If no config name is given
      # "default" is used.
      #
      name: "default",
      #
      # These are the files included in the analysis:
      files: %{
        #
        # You can give explicit globs or simply directories.
        # In the latter case `**/*.{ex,exs}` will be used.
        #
        included: [
          "lib/",
          "src/",
          "test/",
          "web/",
          "apps/*/lib/",
          "apps/*/src/",
          "apps/*/test/",
          "apps/*/web/"
        ],
        excluded: [~r"/_build/", ~r"/deps/", ~r"/node_modules/"]
      },
      #
      # Load and configure plugins here:
      #
      plugins: [],
      #
      # If you create your own checks, you must specify the source files for
      # them here, so they can be loaded by Credo before running the analysis.
      #
      requires: [],
      #
      # If you want to enforce a style guide and need a more traditional linting
      # experience, you can change `strict` to `true` below:
      #
      strict: true,
      #
      # To modify the timeout for parsing files, change this value:
      #
      parse_timeout: 5000,
      #
      # If you want to use uncolored output by default, you can change `color`
      # to `false` below:
      #
      color: true,
      #
      # You can customize the parameters of any check by adding a second element
      # to the tuple.
      #
      # To disable a check put `false` as second element:
      #
      #     {Credo.Check.Design.DuplicatedCode, false}
      #
      checks: %{
        enabled: [
          #
          ## Consistency Checks
          #
          {Credo.Check.Consistency.ExceptionNames, []},
          {Credo.Check.Consistency.LineEndings, []},
          {Credo.Check.Consistency.ParameterPatternMatching, []},
          {Credo.Check.Consistency.SpaceAroundOperators, []},
          {Credo.Check.Consistency.SpaceInParentheses, []},
          {Credo.Check.Consistency.TabsOrSpaces, []},

          #
          ## Design Checks
          #
          # You can customize the priority of any check
          # Priority values are: `low, normal, high, higher`
          #
          {Credo.Check.Design.AliasUsage,
           [
             priority: :low,
             if_nested_deeper_than: 2,
             # A single fully-qualified call reads fine; only ask for an alias
             # once a nested module is used more than once.
             if_called_more_often_than: 1,
             files: %{excluded: baseline_alias_usage}
           ]},
          {Credo.Check.Design.TagFIXME, []},
          # You can also customize the exit_status of each check.
          # If you don't want TODO comments to cause `mix credo` to fail, just
          # set this value to 0 (zero).
          #
          {Credo.Check.Design.TagTODO, [exit_status: 2]},

          #
          ## Readability Checks
          #
          {Credo.Check.Readability.AliasOrder, [files: %{excluded: baseline_alias_order}]},
          {Credo.Check.Readability.FunctionNames, []},
          {Credo.Check.Readability.LargeNumbers, []},
          {Credo.Check.Readability.MaxLineLength, [priority: :low, max_length: 120]},
          {Credo.Check.Readability.ModuleAttributeNames, []},
          {Credo.Check.Readability.ModuleDoc, [files: %{excluded: baseline_module_doc}]},
          {Credo.Check.Readability.ModuleNames, []},
          {Credo.Check.Readability.ParenthesesInCondition, []},
          {Credo.Check.Readability.ParenthesesOnZeroArityDefs, []},
          {Credo.Check.Readability.PipeIntoAnonymousFunctions, []},
          {Credo.Check.Readability.PredicateFunctionNames, []},
          {Credo.Check.Readability.PreferImplicitTry, []},
          {Credo.Check.Readability.RedundantBlankLines, []},
          {Credo.Check.Readability.Semicolons, []},
          {Credo.Check.Readability.SpaceAfterCommas, []},
          {Credo.Check.Readability.StringSigils, []},
          {Credo.Check.Readability.TrailingBlankLine, []},
          {Credo.Check.Readability.TrailingWhiteSpace, []},
          {Credo.Check.Readability.UnnecessaryAliasExpansion, []},
          {Credo.Check.Readability.VariableNames, []},
          # Baseline: whatsapp_infobip.ex is being changed by in-flight PRs.
          {Credo.Check.Readability.WithSingleClause,
           [files: %{excluded: ["lib/converger/channels/adapters/whatsapp_infobip.ex"]}]},

          #
          ## Refactoring Opportunities
          #
          # Converger.Channels.Adapter dispatches *optional* behaviour callbacks
          # with apply/3 after function_exported?/3; a direct `mod.fun()` call
          # there makes the compiler warn for adapters that do not implement
          # the callback.
          {Credo.Check.Refactor.Apply,
           [files: %{excluded: ["lib/converger/channels/adapter.ex"]}]},
          {Credo.Check.Refactor.CondStatements, []},
          {Credo.Check.Refactor.CyclomaticComplexity, []},
          {Credo.Check.Refactor.FilterCount, []},
          # Baseline: pipeline.ex is being changed by in-flight PRs.
          {Credo.Check.Refactor.FilterFilter,
           [files: %{excluded: ["lib/converger/pipeline.ex"]}]},
          {Credo.Check.Refactor.FunctionArity, []},
          {Credo.Check.Refactor.LongQuoteBlocks, []},
          {Credo.Check.Refactor.MapJoin, []},
          {Credo.Check.Refactor.MatchInCondition, []},
          {Credo.Check.Refactor.NegatedConditionsInUnless, []},
          {Credo.Check.Refactor.NegatedConditionsWithElse, []},
          # Callbacks of the "authorize -> run -> branch on result" shape
          # (LiveView events, plugs, storage backends) routinely need one more
          # level than the default of 2. Baseline: activities.ex (depth 4) is
          # being changed by in-flight PRs.
          {Credo.Check.Refactor.Nesting,
           [max_nesting: 3, files: %{excluded: ["lib/converger/activities.ex"]}]},
          {Credo.Check.Refactor.RedundantWithClauseResult, []},
          {Credo.Check.Refactor.RejectReject, []},
          {Credo.Check.Refactor.UnlessWithElse, []},
          {Credo.Check.Refactor.WithClauses, []},

          #
          ## Warnings
          #
          {Credo.Check.Warning.ApplicationConfigInModuleAttribute, []},
          {Credo.Check.Warning.BoolOperationOnSameValues, []},
          {Credo.Check.Warning.Dbg, []},
          {Credo.Check.Warning.ExpensiveEmptyEnumCheck, []},
          {Credo.Check.Warning.IExPry, []},
          {Credo.Check.Warning.IoInspect, []},
          # Production logs every metadata key (`metadata: :all` in
          # config/prod.exs, JSON formatter); the dev console format only shows
          # request_id on purpose. These are the structured keys the code uses.
          {Credo.Check.Warning.MissedMetadataKeyInLoggerConfig,
           [
             metadata_keys: [
               :action,
               :activity_id,
               :attempts,
               :cap,
               :channel_id,
               :channel_type,
               :claims,
               :conversation_id,
               :count,
               :counts,
               :data,
               :delivery_id,
               :error,
               :errors,
               :legacy,
               :month,
               :partition,
               :partitions,
               :processed,
               :reason,
               :rows,
               :signal,
               :source,
               :status,
               :tenant_id,
               :total
             ]
           ]},
          {Credo.Check.Warning.OperationOnSameValues, []},
          {Credo.Check.Warning.OperationWithConstantResult, []},
          {Credo.Check.Warning.RaiseInsideRescue, []},
          {Credo.Check.Warning.SpecWithStruct, []},
          {Credo.Check.Warning.StructFieldAmount, []},
          {Credo.Check.Warning.UnsafeExec, []},
          {Credo.Check.Warning.UnusedEnumOperation, []},
          {Credo.Check.Warning.UnusedFileOperation, []},
          {Credo.Check.Warning.UnusedKeywordOperation, []},
          {Credo.Check.Warning.UnusedListOperation, []},
          {Credo.Check.Warning.UnusedMapOperation, []},
          {Credo.Check.Warning.UnusedPathOperation, []},
          {Credo.Check.Warning.UnusedRegexOperation, []},
          {Credo.Check.Warning.UnusedStringOperation, []},
          {Credo.Check.Warning.UnusedTupleOperation, []},
          {Credo.Check.Warning.WrongTestFilename, []}
        ],
        disabled: [
          #
          # Checks scheduled for next check update (opt-in for now)
          {Credo.Check.Refactor.UtcNowTruncate, []},

          #
          # Controversial and experimental checks (opt-in, just move the check to `:enabled`
          #   and be sure to use `mix credo --strict` to see low priority checks)
          #
          {Credo.Check.Consistency.MultiAliasImportRequireUse, []},
          {Credo.Check.Consistency.UnusedVariableNames, []},
          {Credo.Check.Design.DuplicatedCode, []},
          {Credo.Check.Design.SkipTestWithoutComment, []},
          {Credo.Check.Readability.AliasAs, []},
          {Credo.Check.Readability.BlockPipe, []},
          {Credo.Check.Readability.ImplTrue, []},
          {Credo.Check.Readability.MultiAlias, []},
          {Credo.Check.Readability.NestedFunctionCalls, []},
          {Credo.Check.Readability.OneArityFunctionInPipe, []},
          {Credo.Check.Readability.OnePipePerLine, []},
          {Credo.Check.Readability.SeparateAliasRequire, []},
          {Credo.Check.Readability.SingleFunctionToBlockPipe, []},
          {Credo.Check.Readability.SinglePipe, []},
          {Credo.Check.Readability.Specs, []},
          {Credo.Check.Readability.StrictModuleLayout, []},
          {Credo.Check.Readability.WithCustomTaggedTuple, []},
          {Credo.Check.Refactor.ABCSize, []},
          {Credo.Check.Refactor.AppendSingleItem, []},
          {Credo.Check.Refactor.CondInsteadOfIfElse, []},
          {Credo.Check.Refactor.DoubleBooleanNegation, []},
          {Credo.Check.Refactor.FilterReject, []},
          {Credo.Check.Refactor.IoPuts, []},
          {Credo.Check.Refactor.MapMap, []},
          {Credo.Check.Refactor.ModuleDependencies, []},
          {Credo.Check.Refactor.NegatedIsNil, []},
          {Credo.Check.Refactor.PassAsyncInTestCases, []},
          {Credo.Check.Refactor.PipeChainStart, []},
          {Credo.Check.Refactor.RejectFilter, []},
          {Credo.Check.Refactor.VariableRebinding, []},
          {Credo.Check.Warning.LazyLogging, []},
          {Credo.Check.Warning.LeakyEnvironment, []},
          {Credo.Check.Warning.MapGetUnsafePass, []},
          {Credo.Check.Warning.MixEnv, []},
          {Credo.Check.Warning.UnsafeToAtom, []}
          # {Credo.Check.Warning.UnusedOperation, [{MyMagicModule, [:fun1, :fun2]}]}

          # {Credo.Check.Refactor.MapInto, []},

          #
          # Custom checks can be created using `mix credo.gen.check`.
          #
        ]
      }
    }
  ]
}
