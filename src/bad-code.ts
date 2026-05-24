// SonarCloud bad-PR drill — AC-08
// Three patterns across syntax and type levels for maximum reliability:
//
// typescript:S3923 — All branches in a conditional have the same implementation (BUG)
//   Purely syntactic — fires without TypeScript type info
//
// typescript:S1764 — Identical expressions on both sides of operator (BUG)
//
// typescript:S2259 — Null dereference (BUG, needs strict tsconfig)

export function getStatus(isActive: boolean): string {
  if (isActive) {
    return 'active'; // S3923: both branches identical — dead logic
  } else {
    return 'active';
  }
}

export function validateRole(role: string): boolean {
  return role === role; // S1764: always returns true
}

export function getUserName(user: { name: string } | null): string {
  return user.name; // S2259: user can be null — null dereference
}
