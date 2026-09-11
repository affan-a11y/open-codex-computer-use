# Agent loop integration

Implement the missing harness support for creator-agent's approved design.
Keep the existing targeted-query and snapshot-free action changes.

- [x] Create the agent display before app discovery finishes; prepare windows
  without taking an extra full snapshot first.
- [x] Observe an explicitly selected window without activation or recovery.
- [x] Report attempted and completed statements, including failures and statements
  executed by the final feed. Deliver progress while the statement runs.
- [x] Do not execute incomplete if/else or try/catch blocks.
- [x] Test the wire, parser and read paths; update references and history.

The caller owns program files, observation scheduling and Hyperopia. These do
not belong in the desktop service. Verify with unit tests and designated local
apps; do not run the example email flow.


Validation: the 39 focused JavaScript/bridge/stream tests passed. The final
OpenComputerUse debug product built. A live Finder check prepared the display
and window, read its AX tree and image from a separate process, and queried two
controls in the persistent runtime. The runtime then closed normally.

App preparation reuses AppDiscovery with activation disabled. The new-window
route is implemented but was not exercised in this live check. Claude's active
query/action changes were preserved; they are separate from this integration.

Apple App Intent execution inside the JS program remains unimplemented.
macOS rejected the tested LinkServices call. The Shortcuts adapter was removed
because it did not implement execution by app/action identity and parameters.
