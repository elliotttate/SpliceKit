# Offline and live verification

`make test` (or `python3 -m tests.run`) runs every FCP-free unittest suite, including
the loopback mock RPC acceptance tests and generated AVFoundation fixtures. It never
imports the legacy executable `test_ai_command.py` or `test_mcp_endpoints.py` integration
scripts. macOS-only GPU/media tests report explicit skips on other platforms.

Most tests use the Python standard library. Two existing OTIO fixture tests are
optional without OTIO. To run them as CI does, use Python 3.12 and the exact adapter
source recorded with the bundled fixtures:

```sh
python3.12 -m venv build/offline-venv
build/offline-venv/bin/python -m pip install --only-binary=opentimelineio -r tests/requirements-offline.txt -r mcp/requirements.txt
git clone https://github.com/OpenTimelineIO/otio-fcpx-xml-adapter.git build/otio-fixture-adapter
git -C build/otio-fixture-adapter checkout 20d9fa54141149c09d976f3520a8c29d8e5ad124
make test TEST_PYTHON=build/offline-venv/bin/python
```

The runner loads that checkout's plugin manifest directly; the adapter commit's
packaging references `LICENSE` while its repository has `LICENSE.md`. Do not install
the old PyPI 1.0 adapter as a substitute for these 2.0 source fixtures. If using another
adapter location, set `OTIO_PLUGIN_MANIFEST_PATH` explicitly and set
`OTIO_DISABLE_ENTRYPOINTS_PLUGINS=1` to avoid unrelated installed adapters.

The transition sample itself has inconsistent declared sequence/spine durations. Its
offline regression checks the pinned adapter's three 10-second clips and two overlapping
OTIO transitions (30 seconds), rather than claiming that its declared FCP duration was
validated. The package fixture contains four named projects, all checked explicitly.

For guarded live verification see [the plan contract](live/v4/SCHEMA.md) and
[fixture instructions](live/fixtures/README.md). GitHub Actions builds the universal
library and runs this suite on macOS; it never deploys, installs, or launches FCP.

V4 integration: 49 native registrations match 49 native descriptors, plus four
Python capabilities. `python -m tests.live.run_live --check-plans` validates all
eight plans without connecting. The default suite has 46 ordered steps and stays
template-fenced until native fixture IDs are bound. See the
[integration README](../docs/v4/README.md) and [recorded validation](../docs/v4/VALIDATION.md).
The supplied Python 3.14 environment has two OTIO `bad any cast` errors also
reproduced by `python -m tests.verify_otio_upstream`; Python 3.12 with the pinned
adapter passes all 171 current tests. No skips/xfails were added for these errors.
