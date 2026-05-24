// AC-08 drill — bug fixed, gate should pass
// All three S3923 / S1764 / S2259 patterns corrected below

export function getStatus(isActive: boolean): string {
  return isActive ? 'active' : 'inactive';
}

export function validateRole(role: string, expected: string): boolean {
  return role === expected;
}

export function getUserName(user: { name: string } | null): string {
  return user?.name ?? 'unknown';
}
