import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import {test, assertEqual} from './harness.js';
import {parseProcStat, parseMeminfo, parsePressureSomeAvg10, parseProcSwaps, parseZramMmStat, parseUid}
    from '../extensions/resource-pulse@dotfiles/lib/procParsers.js';
import {parseCpuStatUsageUsec, parseMemoryStatReclaimableBytes, parseSingleNumber}
    from '../extensions/resource-pulse@dotfiles/lib/cgroupParsers.js';

const REAL_FIXTURE_DIRECTORY_URI = GLib.uri_resolve_relative(import.meta.url, './fixtures/real/', GLib.UriFlags.NONE);
const EXPECTED_REAL_CPU_COUNT = 8;
const BYTES_PER_KIB = 1024;
/** /proc/swaps's header, as the kernel writes it (tab separated). */
const PROC_SWAPS_HEADER = 'Filename\t\t\t\tType\t\tSize\t\tUsed\t\tPriority\n';

/**
 * Reads a committed real capture from fixtures/real/ (tests may block).
 *
 * @param {string} fileName - Capture file name.
 * @returns {string} File contents.
 */
function readRealFixture(fileName) {
    const file = Gio.File.new_for_uri(`${REAL_FIXTURE_DIRECTORY_URI}${fileName}`);
    const [, bytes] = file.load_contents(null);
    return new TextDecoder().decode(bytes);
}

test('mm_stat: RAM cost is mem_used_total (field 3), not compr_data_size (field 2)', () => {
    const zram = parseZramMmStat('1567870976 386016017 397680640        0 397688832     2083     3855     2147     2687\n');
    assertEqual(zram, {storedBytes: 1567870976, ramBytes: 397680640});
});
test('mm_stat: the real capture parses', () => {
    const zram = parseZramMmStat(readRealFixture('zram-mm_stat'));
    assertEqual(zram !== null && zram.storedBytes > 0 && zram.ramBytes > 0, true);
});
test('meminfo: kB values become bytes', () =>
    assertEqual(parseMeminfo('MemTotal:       32000000 kB\nMemAvailable:   12000000 kB\n').get('MemAvailable'), 12000000 * 1024));
test('meminfo: the real capture has MemTotal and MemAvailable', () => {
    const meminfo = parseMeminfo(readRealFixture('meminfo'));
    assertEqual([meminfo.has('MemTotal'), meminfo.has('MemAvailable')], [true, true]);
});
test('PSI: reads the some line avg10, ignores the full line', () =>
    assertEqual(parsePressureSomeAvg10('some avg10=4.70 avg60=5.19 avg300=4.63 total=1\nfull avg10=9.00 avg60=0 avg300=0 total=0\n'), 4.7));
test('PSI: the real capture parses to a number', () =>
    assertEqual(typeof parsePressureSomeAvg10(readRealFixture('pressure-cpu')), 'number'));
test('/proc/stat: guest and guest_nice parse into their own fields', () => {
    const {aggregate} = parseProcStat('cpu  100 0 100 700 100 0 0 0 50 7\ncpu0 100 0 100 700 100 0 0 0 50 7\n');
    assertEqual([aggregate.guest, aggregate.guestNice], [50, 7]);
});
test('/proc/stat: the real capture yields 8 per-CPU entries', () => {
    const parsed = parseProcStat(readRealFixture('proc-stat'));
    assertEqual(parsed.perCpu.size, EXPECTED_REAL_CPU_COUNT);
});
test('malformed lines yield null, never NaN', () => {
    assertEqual(parseZramMmStat('garbage\n'), null);
    assertEqual(parsePressureSomeAvg10('garbage\n'), null);
    assertEqual(parseUid('Name:\tx\n'), null);
    assertEqual(parseCpuStatUsageUsec('garbage\n'), null);
});
test('memory.stat: reclaimable = active_file + inactive_file', () =>
    assertEqual(parseMemoryStatReclaimableBytes('anon 10\nactive_file 300\ninactive_file 200\nshmem 5\n'), 500));
test('cpu.stat: usage_usec', () => assertEqual(parseCpuStatUsageUsec('usage_usec 89812225000\nuser_usec 1\n'), 89812225000));
test('status: Uid', () => assertEqual(parseUid('Name:\tgnome-shell\nUid:\t1000\t1000\t1000\t1000\n'), 1000));
test('memory.current: a single number parses, "max" is null', () => {
    assertEqual(parseSingleNumber('4096\n'), 4096);
    assertEqual(parseSingleNumber('max\n'), null);
});

test('/proc/swaps: each area\'s Used column, KiB → bytes, from the real tab-and-space-separated capture', () =>
    assertEqual(parseProcSwaps(readRealFixture('proc-swaps')), [
        {filename: '/swap.img', usedBytes: 0},
        {filename: '/dev/zram0', usedBytes: 5_594_672 * BYTES_PER_KIB},
    ]));
test('/proc/swaps: a header with no area under it is an empty list (no swap), not no data', () =>
    assertEqual(parseProcSwaps(PROC_SWAPS_HEADER), []));
test('/proc/swaps: a malformed Used, a row short of a column or a header without Used is no data (null)', () =>
    assertEqual([
        parseProcSwaps(`${PROC_SWAPS_HEADER}/swap.img\tfile\t8388604\tmany\t-1\n`),
        // Every column up to Used is there, so only the column count can refuse it.
        parseProcSwaps(`${PROC_SWAPS_HEADER}/swap.img\tfile\t8388604\t0\n`),
        parseProcSwaps('Filename\tType\tSize\tPriority\n/swap.img\tfile\t8388604\t-1\n'),
        parseProcSwaps(''),
    ], [null, null, null, null]));
