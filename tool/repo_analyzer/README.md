# repo_analyzer

Internal analyzer plugin that enforces the xcross workspace architecture. It is
enabled for every workspace package through the root `analysis_options.yaml`:

```yaml
plugins:
  repo_analyzer:
    path: tool/repo_analyzer
```

so `dart analyze`, IDEs, and CI all report the same diagnostics. CI runs
`dart analyze --fatal-warnings`.

## No registries

The previous `tool/architecture` guard needed every composition file, host
factory, assembly, and public declaration to be listed by hand. This plugin
derives everything from conventions, so a new component needs no linter edits.

| Concern | Convention |
| --- | --- |
| Composition roots | `lib/[src/]composition/**`, `bin/`, `tool/`, `hook/` |
| Host ownership | `lib/[src/]host/<os>/**` (`host/shared` is shared) |
| Target ownership | `lib/[src/]target/<device>/**`, also nested below `host/<os>/` |
| Platform identity types | `PlatformHostInterface`, `PlatformTargetInterface`, `*PlatformInterface`, and their subtypes |
| Services | native effect handles, HTTP clients, hosts, abstract interfaces with `void`/`Future` commands, and anything holding one |
| Visibility | public top-level declarations in `lib/src/`, `*_test.dart`, `tool/`, `bin/`, `hook/` must be `@internal` |
| Fixtures | packages nested under another package's `test/` or `example/` are skipped |

## Rules

Every rule is a warning, so it is on by default. To suppress one,
write `// ignore: repo_analyzer/<rule>` with a justification.

* Platform composition: `platform_branch`, `platform_identity_bool`,
  `platform_registry`, `platform_visitor`, `platform_callback_dispatch`,
  `ambient_platform_state`, `hidden_platform_detection`, `native_acquisition`.
* Layering: `composition_edge`, `concrete_platform_edge`, `library_layout`,
  `thin_entrypoint`.
* Declarations and DI: `private_type`, `direct_import`, `missing_internal`,
  `global_service`, `hidden_dependency`, `ambient_network`,
  `target_host_bound`.

## Development

```sh
cd tool/repo_analyzer && dart test
```

After changing rules, restart the analysis server (or rerun `dart analyze`)
to rebuild the plugin snapshot.
