// The Shell glue (extension.js, indicator.js, card.js) imports the Shell, so plain gjs stops at its first
// resource:/// import and never checks its other imports: a name renamed in lib/ that only the glue imports would
// surface only as an ERROR state at the next login. These rows check every relative import of the glue by reading
// the sources. The reading is deliberately narrow, and an import or export it does not understand fails the row
// rather than being skipped.
import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import {test, assertEqual} from './harness.js';

const EXTENSION_DIRECTORY_URI =
    GLib.uri_resolve_relative(import.meta.url, '../extensions/resource-pulse@dotfiles/', GLib.UriFlags.NONE);
const [EXTENSION_DIRECTORY_PATH] = GLib.filename_from_uri(EXTENSION_DIRECTORY_URI);
const GLUE_FILE_NAMES = [
    'extension.js', 'indicator.js', 'card.js', 'cockpitTooltip.js', 'cockpitCards.js', 'cockpitLayer.js',
];
/** The modules outside lib/ that plain gjs can load (lib/ is listed from the disk). */
const PURE_TOP_LEVEL_FILE_NAMES = [
    'pulseClient.js', 'serviceLink.js', 'cockpitClient.js', 'displayConfig.js', 'graph.js',
];
const LIB_DIRECTORY_NAME = 'lib';
const JAVASCRIPT_SUFFIX = '.js';
const SHELL_RESOURCE_PREFIX = 'resource:///';
/** Any line that starts an import; each must be one IMPORT_STATEMENT_PATTERN reads. */
const IMPORT_LINE_PATTERN = /^import\b/gm;
/** `import <clause> from '<specifier>';`, the clause possibly over several lines. */
const IMPORT_STATEMENT_PATTERN = /^import\s+([^;]*?)\s+from\s+'([^']+)';/gm;
/** A relative specifier as it appears after `from`, counted independently of the statement pattern. */
const RELATIVE_FROM_PATTERN = /\bfrom\s+'\.\.?\//g;
const NAMED_IMPORTS_PATTERN = /^\{([^}]*)\}$/;
const NAMESPACE_IMPORT_PATTERN = /^\*\s+as\s+[A-Za-z_$][\w$]*$/;
const DEFAULT_IMPORT_PATTERN = /^[A-Za-z_$][\w$]*$/;
const IMPORT_SPECIFIER_PATTERN = /^([A-Za-z_$][\w$]*)(?:\s+as\s+[A-Za-z_$][\w$]*)?$/;
const RELATIVE_SPECIFIER_PATTERN = /^\.\.?\//;
const DEFAULT_EXPORT_NAME = 'default';
/** Any line that starts an export; each must be one EXPORT_DECLARATION_PATTERN reads. */
const EXPORT_LINE_PATTERN = /^export\b.*$/gm;
const EXPORT_DECLARATION_PATTERN = /^export\s+(?:async\s+)?(?:function\*?|class|const|let|var)\s+([A-Za-z_$][\w$]*)/;

/**
 * Reads a file of the extension as text (tests may block).
 *
 * @param {string} path - Absolute path.
 * @returns {string} Its contents.
 */
function readSource(path) {
    const [, contentBytes] = Gio.File.new_for_path(path).load_contents(null);
    return new TextDecoder().decode(contentBytes);
}

/**
 * The names an import clause takes from its module.
 *
 * @param {string} clause - What stands between `import` and `from`.
 * @param {string} where - The file and specifier, for an error message.
 * @returns {string[]} The imported names ('default' for a default import, none for a namespace import).
 * @throws {Error} For a clause shape this row does not read.
 */
function importedNames(clause, where) {
    const trimmedClause = clause.trim();
    const namedMatch = NAMED_IMPORTS_PATTERN.exec(trimmedClause);
    if (namedMatch !== null) {
        const specifiers = namedMatch[1].split(',').map(specifier => specifier.trim()).filter(Boolean);
        return specifiers.map(specifier => {
            const specifierMatch = IMPORT_SPECIFIER_PATTERN.exec(specifier);
            if (specifierMatch === null)
                throw new Error(`${where}: cannot read the import specifier '${specifier}'`);
            return specifierMatch[1];
        });
    }
    if (NAMESPACE_IMPORT_PATTERN.test(trimmedClause))
        return [];
    if (DEFAULT_IMPORT_PATTERN.test(trimmedClause))
        return [DEFAULT_EXPORT_NAME];
    throw new Error(`${where}: cannot read the import clause '${trimmedClause}'`);
}

/**
 * Every import statement of a source file.
 *
 * @param {string} sourceText - The file's text.
 * @param {string} fileName - For error messages.
 * @returns {Array<{specifier: string, names: string[]}>} One entry per statement.
 * @throws {Error} When a line starts an import that is not a statement this row reads (a side-effect import, for
 *     example).
 */
function importStatements(sourceText, fileName) {
    const statements = [...sourceText.matchAll(IMPORT_STATEMENT_PATTERN)].map(([, clause, specifier]) =>
        ({specifier, names: importedNames(clause, `${fileName} '${specifier}'`)}));
    const importLineCount = (sourceText.match(IMPORT_LINE_PATTERN) ?? []).length;
    if (importLineCount !== statements.length)
        throw new Error(`${fileName}: ${importLineCount} import lines, but only ${statements.length} statements read`);
    return statements;
}

/**
 * The names a source file exports, read from its text: only `export [async] function|class|const|let|var Name`.
 *
 * @param {string} sourceText - The file's text.
 * @param {string} fileName - For error messages.
 * @returns {string[]} The exported names.
 * @throws {Error} For any other export line (`export {…}`, `export default`, `export *`), which this row does
 *     not read.
 */
function exportsReadFromSource(sourceText, fileName) {
    return (sourceText.match(EXPORT_LINE_PATTERN) ?? []).map(exportLine => {
        const declarationMatch = EXPORT_DECLARATION_PATTERN.exec(exportLine);
        if (declarationMatch === null)
            throw new Error(`${fileName}: cannot read the export line '${exportLine}'`);
        return declarationMatch[1];
    });
}

/**
 * The names a module exports: from a real import when plain gjs can load it, else read from its text (a module
 * that imports the Shell).
 *
 * @param {string} modulePath - Absolute path.
 * @returns {Promise<string[]>} The exported names.
 */
async function exportedNames(modulePath) {
    const sourceText = readSource(modulePath);
    if (sourceText.includes(SHELL_RESOURCE_PREFIX))
        return exportsReadFromSource(sourceText, GLib.path_get_basename(modulePath));
    const moduleNamespace = await import(GLib.filename_to_uri(modulePath, null));
    return Object.keys(moduleNamespace);
}

/**
 * Every module plain gjs can load: lib/*.js, pulseClient.js, serviceLink.js, cockpitClient.js, displayConfig.js and
 * graph.js.
 *
 * @returns {string[]} Absolute paths.
 */
function pureModulePaths() {
    const libPath = GLib.build_filenamev([EXTENSION_DIRECTORY_PATH, LIB_DIRECTORY_NAME]);
    const enumerator = Gio.File.new_for_path(libPath)
        .enumerate_children('standard::name', Gio.FileQueryInfoFlags.NONE, null);
    const libFileNames = [];
    for (let fileInfo = enumerator.next_file(null); fileInfo !== null; fileInfo = enumerator.next_file(null)) {
        if (fileInfo.get_name().endsWith(JAVASCRIPT_SUFFIX))
            libFileNames.push(fileInfo.get_name());
    }
    enumerator.close(null);
    return [
        ...PURE_TOP_LEVEL_FILE_NAMES.map(fileName => GLib.build_filenamev([EXTENSION_DIRECTORY_PATH, fileName])),
        ...libFileNames.sort().map(fileName => GLib.build_filenamev([libPath, fileName])),
    ];
}

test('every relative import in extension.js, indicator.js and card.js names a file that exports each name', async () => {
    const problems = [];
    const relativeImportCounts = {};
    for (const glueFileName of GLUE_FILE_NAMES) {
        const gluePath = GLib.build_filenamev([EXTENSION_DIRECTORY_PATH, glueFileName]);
        const sourceText = readSource(gluePath);
        const relativeStatements = importStatements(sourceText, glueFileName)
            .filter(statement => RELATIVE_SPECIFIER_PATTERN.test(statement.specifier));
        // Counted a second, independent way, so a statement the pattern above missed cannot pass unchecked.
        const relativeFromCount = (sourceText.match(RELATIVE_FROM_PATTERN) ?? []).length;
        relativeImportCounts[glueFileName] = relativeStatements.length === relativeFromCount && relativeFromCount > 0;
        for (const {specifier, names} of relativeStatements) {
            const targetPath = GLib.canonicalize_filename(specifier, GLib.path_get_dirname(gluePath));
            if (!GLib.file_test(targetPath, GLib.FileTest.IS_REGULAR)) {
                problems.push(`${glueFileName}: no file ${specifier}`);
                continue;
            }
            const targetExports = new Set(await exportedNames(targetPath));
            for (const name of names.filter(importedName => !targetExports.has(importedName)))
                problems.push(`${glueFileName}: ${specifier} exports no ${name}`);
        }
    }
    assertEqual([problems, relativeImportCounts],
        [[], Object.fromEntries(GLUE_FILE_NAMES.map(glueFileName => [glueFileName, true]))]);
});

test('reading exports from the source finds what a real import finds, in every module plain gjs can load', async () => {
    const disagreements = [];
    for (const modulePath of pureModulePaths()) {
        const moduleName = GLib.path_get_basename(modulePath);
        const readNames = exportsReadFromSource(readSource(modulePath), moduleName).sort();
        const importedNamesSorted = Object.keys(await import(GLib.filename_to_uri(modulePath, null))).sort();
        if (JSON.stringify(readNames) !== JSON.stringify(importedNamesSorted))
            disagreements.push(`${moduleName}: read ${readNames.join(',')}; imported ${importedNamesSorted.join(',')}`);
    }
    assertEqual(disagreements, []);
});
