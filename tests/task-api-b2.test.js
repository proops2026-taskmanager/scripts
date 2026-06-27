// B2 test runner: collect all failures (don't stop on first)
const failures = [];

function check(actual, expected, label) {
  if (actual !== expected) {
    failures.push({ label, actual, expected });
    console.error(`FAIL: ${label}`);
    console.error(`  expected: ${JSON.stringify(expected)}`);
    console.error(`  received: ${JSON.stringify(actual)}`);
  }
}

// ── Bug 1: task status validation (task-api.js line 14) ───────────────────────
// Spec: 'completed' is a valid terminal status
// Bug: missing 'completed' from the allowed list
function validateTaskStatus(status) {
  const valid = ['todo', 'in-progress', 'done']; // BUG: 'completed' missing
  return valid.includes(status);
}

check(validateTaskStatus('todo'),        true,  'validateTaskStatus: todo → valid');
check(validateTaskStatus('in-progress'), true,  'validateTaskStatus: in-progress → valid');
check(validateTaskStatus('done'),        true,  'validateTaskStatus: done → valid');
check(validateTaskStatus('completed'),   true,  'validateTaskStatus: completed → valid (task-api.js:14)');

// ── Bug 2: task priority scoring (priority-service.js line 22) ────────────────
// Spec: score >= 8 → HIGH; score >= 5 → MEDIUM; score < 5 → LOW
// Bug: > 5 instead of >= 5 — score exactly 5 incorrectly returns LOW
function priorityFromScore(score) {
  if (score >= 8) return 'HIGH';
  if (score > 5)  return 'MEDIUM'; // BUG: should be >= 5
  return 'LOW';
}

check(priorityFromScore(9), 'HIGH',   'priorityFromScore: 9 → HIGH');
check(priorityFromScore(7), 'MEDIUM', 'priorityFromScore: 7 → MEDIUM');
check(priorityFromScore(5), 'MEDIUM', 'priorityFromScore: 5 → MEDIUM (priority-service.js:22)');
check(priorityFromScore(3), 'LOW',    'priorityFromScore: 3 → LOW');

if (failures.length > 0) {
  console.error(`\n${failures.length} test(s) failed.`);
  process.exit(1);
}

console.log('All tests passed.');
