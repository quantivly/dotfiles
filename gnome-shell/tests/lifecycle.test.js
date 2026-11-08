// Rows for the pieces of the extension's lifecycle that run under plain gjs: lib/teardown.js, which runs each
// teardown step under its own guard, and lib/errorLog.js, the rate-limited journal lines the sampler and the
// extension share. extension.js itself imports the Shell, so its use of them is pinned by the state table's
// file rows.
import {test, assertEqual} from './harness.js';
import {runEveryStep} from '../extensions/resource-pulse@dotfiles/lib/teardown.js';
import {RateLimitedLogger} from '../extensions/resource-pulse@dotfiles/lib/errorLog.js';
import {ERROR_LOG_REPEAT_INTERVAL_USEC, LOG_PREFIX} from '../extensions/resource-pulse@dotfiles/lib/constants.js';

const ONE_SECOND_USEC = 1_000_000;

/**
 * A teardown step that records that it ran, and throws when asked to.
 *
 * @param {string} name - The step's name.
 * @param {string[]} ranSteps - Receives the name when the step runs.
 * @param {boolean} [shouldThrow] - True to throw after recording.
 * @returns {{name: string, run: () => void}} The step.
 */
function recordingStep(name, ranSteps, shouldThrow = false) {
    return {
        name,
        run: () => {
            ranSteps.push(name);
            if (shouldThrow)
                throw new Error(`${name} exploded`);
        },
    };
}

test('runEveryStep: a throwing step neither stops the steps after it nor escapes, and is reported by name', () => {
    const ranSteps = [];
    const reported = [];
    const failedStepCount = runEveryStep([
        recordingStep('destroy the card', ranSteps),
        recordingStep('destroy the indicator', ranSteps, true),
        recordingStep('destroy the sampler', ranSteps),
    ], (stepName, error) => reported.push([stepName, error.message]));
    assertEqual([ranSteps, reported, failedStepCount], [
        ['destroy the card', 'destroy the indicator', 'destroy the sampler'],
        [['destroy the indicator', 'destroy the indicator exploded']],
        1,
    ]);
});

test('runEveryStep: every throwing step is reported in order, and a reporter that throws cannot stop the rest', () => {
    const ranSteps = [];
    const reportedStepNames = [];
    const failedStepCount = runEveryStep([
        recordingStep('first', ranSteps, true),
        recordingStep('second', ranSteps, true),
        recordingStep('third', ranSteps),
    ], stepName => {
        reportedStepNames.push(stepName);
        throw new Error('the logger exploded');
    });
    assertEqual([ranSteps, reportedStepNames, failedStepCount], [['first', 'second', 'third'], ['first', 'second'], 2]);
});

test('RateLimitedLogger: each message is written once per 10 minutes, prefixed; another message is not held back', () => {
    const clock = {nowUsec: 0};
    const written = [];
    const errorLog = new RateLimitedLogger({nowUsec: () => clock.nowUsec, write: line => written.push(line)});
    errorLog.log('teardown could not destroy the card');
    clock.nowUsec += ONE_SECOND_USEC;
    errorLog.log('teardown could not destroy the card');
    errorLog.log('sampling could not start');
    clock.nowUsec = ERROR_LOG_REPEAT_INTERVAL_USEC;
    errorLog.log('teardown could not destroy the card');
    assertEqual(written, [
        `${LOG_PREFIX} teardown could not destroy the card`,
        `${LOG_PREFIX} sampling could not start`,
        `${LOG_PREFIX} teardown could not destroy the card`,
    ]);
});
