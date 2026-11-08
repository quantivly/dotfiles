// Running a teardown so that one failing step cannot undo the rest. Pure: no Shell import.

/**
 * Runs every step, in order, whatever any of them throws: a step that throws is reported and the next one still
 * runs, so one failure can neither skip the steps after it nor escape and mask an error the caller is already
 * handling.
 *
 * @param {Array<{name: string, run: () => void}>} steps - The steps; a name says what the step does, for the report.
 * @param {(stepName: string, error: *) => void} reportFailure - Called once for each step that threw.
 * @returns {number} How many steps threw.
 */
export function runEveryStep(steps, reportFailure) {
    let failedStepCount = 0;
    for (const step of steps) {
        try {
            step.run();
        } catch (error) {
            failedStepCount++;
            reportWithoutThrowing(reportFailure, step.name, error);
        }
    }
    return failedStepCount;
}

/**
 * Reports a failed step. The reporter is the logger: should it throw too, there is nowhere left to say so, and the
 * steps still to run matter more than this one report, so its own failure is dropped.
 *
 * @param {(stepName: string, error: *) => void} reportFailure - The reporter.
 * @param {string} stepName - The step that threw.
 * @param {*} error - What it threw.
 * @returns {void}
 */
function reportWithoutThrowing(reportFailure, stepName, error) {
    try {
        reportFailure(stepName, error);
    } catch {
        // See above: the report is lost, the teardown goes on.
    }
}
