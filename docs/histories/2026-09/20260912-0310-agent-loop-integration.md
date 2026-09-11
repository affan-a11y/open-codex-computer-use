# Agent loop integration

The user asked for the speculative agent design to be implemented and for the
harness work to remain focused while another contributor worked on queries.

Added explicit display/window preparation and a read of a named window for an
independent observer. Preparation reuses app discovery with activation disabled;
prepared windows remain the runtime's default action/query target.

The pi bridge now reports each attempted and completed statement, including
statements run by the final feed. Failures and abandoned calls retain prior
prints. The stream waits for complete control structures, including continuations
separated by comments. JavaScriptCore checks syntax before execution.

The host still owns program files, background observation scheduling and
Hyperopia. No model or context management was added to the desktop service.

Validation: 39 focused JavaScript/bridge/stream tests passed. The final debug
product built. A live Finder check created the agent display, prepared its
window, captured that window's tree and image independently, and performed a
query in the persistent runtime. The new-browser-window route remains untested
live. Existing query/action work was retained.

Files: AgentPreparation.swift, AgentDisplay.swift, AppDiscovery.swift,
AccessibilitySnapshot.swift, ComputerUseService.swift, ComputerUseToolDispatcher.swift,
JavaScriptToolRuntime.swift, PiBridgeServer.swift, and their protocol/API docs.

The user subsequently requested Apple-intent execution inside the JS program.
macOS rejected the tested LinkServices call, including from a locally signed
app bundle. A Shortcuts adapter was tried and removed because it did not
implement the requested app/action invocation. Apple-intent execution remains
unimplemented.
