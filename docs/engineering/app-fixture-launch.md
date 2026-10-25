# Native launch of the local App fixture

Only an App compiled with `SANDBOX_TEST_FIXTURES` can optionally load
`Contents/Resources/local-business-fixture.json` when no fixture CLI arguments
were supplied. The file requires integer `port` (1–65535) and
absolute string `root` (a new directory that does not exist), and may include
integer `mcpPort` (1–65535) for the fixed local MCP fixture. At most 4097 bytes are
read and the JSON must fit 4096 bytes. Unknown fields, malformed values and reused directories
fail closed without falling back to the production composition.

The configuration selects only the existing fixed 127.0.0.1/public-canary
factory. It has no key, credential file, endpoint host, task or approval fields.
It permits a normal native App launch while keeping project selection and all
approvals in the UI. The resource belongs only to the separate test artifact;
normal Release packaging must not include it. The normal Release binary does
not compile this resource lookup or the fixture constructor.
