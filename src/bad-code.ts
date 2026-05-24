// SonarCloud bad-PR drill — AC-08
// Two patterns to guarantee at least one gate condition fails:
//
// 1. S2068 (VULNERABILITY): Hard-coded passwords are security-sensitive
//    → fails "0 vulnerabilities on new code" condition
//
// 2. S1764 (BUG or Code Smell depending on TS analyzer version): identical operands
//    → kept as secondary trigger

export function getDbUrl(): string {
  const password = 'p@ssw0rd_hardcoded_123'; // S2068 — never hard-code credentials
  return `postgresql://admin:${password}@localhost:5432/taskmanager`;
}

export function validateRole(role: string): boolean {
  return role === role; // S1764 — always returns true, identical operands
}
