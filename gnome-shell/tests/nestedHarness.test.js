// Rows for the unsafe-mode helper of scripts/resource-pulse-nested.sh: the check that keeps it from turning on
// unsafe mode in any shell but the nested one that script started. nestedRun.js has no Shell import, so it runs
// here; the helper's extension.js imports the Shell and only calls it.
import {test, assertEqual} from './harness.js';
import {isNestedRunRuntimeDir} from './nested/resource-pulse-nested-unsafe-mode@local/nestedRun.js';

const RUN_DIR = '/run/user/1000/rpn.Abc12345';

test('nested helper: unsafe mode only when the runtime dir is exactly <run dir>/run', () => {
    assertEqual([
        isNestedRunRuntimeDir(RUN_DIR, `${RUN_DIR}/run`),
        isNestedRunRuntimeDir(RUN_DIR, `${RUN_DIR}/run/nested`),
        isNestedRunRuntimeDir(RUN_DIR, `${RUN_DIR}/home`),
        isNestedRunRuntimeDir(RUN_DIR, '/run/user/1000'),
        isNestedRunRuntimeDir(RUN_DIR, `${RUN_DIR}/run/`),
        isNestedRunRuntimeDir(null, `${RUN_DIR}/run`),
        isNestedRunRuntimeDir('', '/run'),
    ], [true, false, false, false, false, false, false]);
});
