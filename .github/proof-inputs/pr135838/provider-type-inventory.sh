set -euo pipefail
test "$BASE_SHA" = e0c476d18d326d05468135a37ed108e07eb8a466
test "$(git rev-parse HEAD^)" = "$BASE_SHA"
test "$(git rev-parse HEAD^{tree})" = "$EXPECTED_TREE"
test "$EXPECTED_TREE" = 6f3b1f51565d6e06af4eeb314c07833674edc3ef
test "$(git diff --name-only "$BASE_SHA" HEAD)" = test/scripts/type-suppression-inventory.test.ts
git diff --quiet HEAD

/usr/bin/time -f "INVENTORY_FIXED wall_s=%e exit=%x" \
  pnpm test test/scripts/type-suppression-inventory.test.ts --maxWorkers=1 --reporter=verbose
pnpm format:check test/scripts/type-suppression-inventory.test.ts

# Each qualification is tied to the exact fixture text and path. A changed
# annotation must still fail the same native ratchet; restore the owned fixture.
python3 -I - <<'PY'
import pathlib, subprocess, time
fixture = pathlib.Path("src/plugin-sdk/worker-provider.contract.test.ts")
original = fixture.read_bytes()
markers = [
    b"@ts-expect-error V1 requires host-owned invocation options.",
    b"@ts-expect-error V1 cannot provision without a live invocation guard.",
]
try:
    for index, marker in enumerate(markers, 1):
        assert original.count(marker) == 1
        fixture.write_bytes(original.replace(marker, marker + b" qualification-change", 1))
        started = time.monotonic()
        result = subprocess.run(
            ["pnpm", "test", "test/scripts/type-suppression-inventory.test.ts",
             "--maxWorkers=1", "--reporter=verbose", "-t",
             "keeps unchecked any casts at zero and negative type assertions explicit"],
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, check=False,
        )
        print(result.stdout, end="", flush=True)
        print(f"INVENTORY_MUTATION case={index} wall_s={time.monotonic()-started:.3f} exit={result.returncode}", flush=True)
        assert result.returncode == 1, "Changed qualification did not fail normally"
        assert "AssertionError" in result.stdout and "qualification-change" in result.stdout
        assert "keeps unchecked any casts at zero and negative type assertions explicit" in result.stdout
        fixture.write_bytes(original)
finally:
    fixture.write_bytes(original)
PY

git diff --quiet HEAD
test "$(git rev-parse HEAD^{tree})" = "$EXPECTED_TREE"
printf 'INVENTORY_PROOF fixed=passed changed_qualifications_rejected=2 source_restored=true\n'
