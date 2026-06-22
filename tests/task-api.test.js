const assert = require('assert');

// Task status validation
function validateTaskStatus(status) {
  const valid = ['pending', 'in-progress', 'done'];
  return valid.includes(status);
}

assert.strictEqual(validateTaskStatus('pending'), true, 'pending should be valid');
assert.strictEqual(validateTaskStatus('in-progress'), true, 'in-progress should be valid');
assert.strictEqual(validateTaskStatus('done'), true, 'done should be valid');

// Due date calculation — BUG: medium urgency returns 7 days instead of 3
function calculateDueDate(createdAt, urgency) {
  if (urgency === 'high') return createdAt + 24 * 60 * 60 * 1000;
  return createdAt + 7 * 24 * 60 * 60 * 1000; // should be 3 for medium
}

const now = 1_000_000_000_000;
const threeDays = 3 * 24 * 60 * 60 * 1000;

assert.strictEqual(
  calculateDueDate(now, 'medium'),
  now + threeDays,
  'medium urgency task: due date should be 3 days from creation, got 7'
);

console.log('All tests passed');
