// SonarCloud bad-PR drill — intentional bug for AC-08
// Rule S1764: Identical expressions should not be used on both sides of operator
// SonarCloud classifies this as RELIABILITY > BUG → fails "0 bugs on new code" gate

export function validateRole(role: string): boolean {
  return role === role; // always returns true — identical operands
}
