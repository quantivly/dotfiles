// lib/jsonFields.js: the typed readers of untrusted JSON values that every protocol module shares. Each returns the
// value when it is of its type and range, and null otherwise.
import {test, assertEqual} from './harness.js';
import * as jsonFields from '../extensions/resource-pulse@dotfiles/lib/jsonFields.js';

test('jsonFields: parseJsonObject reads an object and rejects a list, a scalar and bad JSON', () => {
    assertEqual(jsonFields.parseJsonObject('{"a":1}'), {a: 1});
    assertEqual(jsonFields.parseJsonObject('[1]'), null);
    assertEqual(jsonFields.parseJsonObject('7'), null);
    assertEqual(jsonFields.parseJsonObject('{nope'), null);
    assertEqual(jsonFields.parseJsonObject(42), null);
});
test('jsonFields: isPlainObject says true for an object only', () => {
    assertEqual(jsonFields.isPlainObject({}), true);
    assertEqual(jsonFields.isPlainObject(null), false);
    assertEqual(jsonFields.isPlainObject([]), false);
    assertEqual(jsonFields.isPlainObject('x'), false);
});
test('jsonFields: finiteNumberOrNull keeps finite numbers only', () => {
    assertEqual(jsonFields.finiteNumberOrNull(-2.5), -2.5);
    assertEqual(jsonFields.finiteNumberOrNull(Infinity), null);
    assertEqual(jsonFields.finiteNumberOrNull(NaN), null);
    assertEqual(jsonFields.finiteNumberOrNull('1'), null);
});
test('jsonFields: nonNegativeNumberOrNull keeps zero or more, finite only', () => {
    assertEqual(jsonFields.nonNegativeNumberOrNull(0), 0);
    assertEqual(jsonFields.nonNegativeNumberOrNull(2.5), 2.5);
    assertEqual(jsonFields.nonNegativeNumberOrNull(-1), null);
    assertEqual(jsonFields.nonNegativeNumberOrNull(Infinity), null);
});
test('jsonFields: fractionOrNull keeps 0 to 1 inclusive only', () => {
    assertEqual(jsonFields.fractionOrNull(0), 0);
    assertEqual(jsonFields.fractionOrNull(1), 1);
    assertEqual(jsonFields.fractionOrNull(1.01), null);
    assertEqual(jsonFields.fractionOrNull(-0.1), null);
});
test('jsonFields: countOrNull keeps whole numbers of zero or more only', () => {
    assertEqual(jsonFields.countOrNull(3), 3);
    assertEqual(jsonFields.countOrNull(0), 0);
    assertEqual(jsonFields.countOrNull(-1), null);
    assertEqual(jsonFields.countOrNull(1.5), null);
    assertEqual(jsonFields.countOrNull(2 ** 53), null);
});
test('jsonFields: stringOrNull keeps strings only', () => {
    assertEqual(jsonFields.stringOrNull('a'), 'a');
    assertEqual(jsonFields.stringOrNull(''), '');
    assertEqual(jsonFields.stringOrNull(1), null);
    assertEqual(jsonFields.stringOrNull(null), null);
});
test('jsonFields: booleanOrNull keeps booleans only', () => {
    assertEqual(jsonFields.booleanOrNull(true), true);
    assertEqual(jsonFields.booleanOrNull(false), false);
    assertEqual(jsonFields.booleanOrNull(0), null);
    assertEqual(jsonFields.booleanOrNull('true'), null);
});
test('jsonFields: enumOrNull keeps a listed string only', () => {
    assertEqual(jsonFields.enumOrNull('working', ['idle', 'working']), 'working');
    assertEqual(jsonFields.enumOrNull('Working', ['idle', 'working']), null);
    assertEqual(jsonFields.enumOrNull(1, ['1']), null);
});
