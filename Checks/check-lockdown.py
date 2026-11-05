"""Exercise real lifecycle/services with a fake gateway; no XCTest/iPad needed."""
from pathlib import Path
import subprocess
import sys
import re

root = Path(__file__).resolve().parent.parent
subprocess.run(["swift", "build", "--target", "Minimuxer"], cwd=root, check=True)
products = Path(subprocess.check_output(
    ["swift", "build", "--show-bin-path"], cwd=root, text=True).strip())

# The aggregate archive bundles both native gateway ABIs with colliding C
# symbols. This check substitutes a fake gateway and compiles the real services
# directly. Omit only the concrete-backend factory, not any lifecycle code.
api = (root / "Sources/MinimuxerApi.swift").read_text()
start = api.index("public final class Minimuxer:")
end = api.index("public protocol EMProxyAPI:", start)
api = api[:start] + api[end:]
api = api.replace("import IdeviceGateway\n", "").replace("import LibimobiledeviceGateway\n", "")
generated = products / "lockdown-check-sources"
generated.mkdir(exist_ok=True)
sources = []
inputs = sorted(p for p in (root / "Sources").rglob("*.swift")
                if p.name not in ["MinimuxerApi.swift", "EMProxyImpl.swift"])
inputs.append(root / "Checks/LockdownRegressionCheck.swift")
for path, text in [(p, p.read_text()) for p in inputs] + [(Path("LockdownCheckAPI.swift"), api)]:
    # Production is built normally above. A single-invocation white-box check
    # needs consistent import visibility across the package's mixed imports.
    text = re.sub(r"^(?:(?:internal|public) )?import ", "public import ", text, flags=re.MULTILINE)
    copy = generated / path.name
    copy.write_text(text)
    sources.append(copy)
runner = products / "lockdown-regression-check"
subprocess.run([
    "swiftc", "-parse-as-library", "-swift-version", "5", "-module-name", "Minimuxer",
    "-I", str(products), "-I", str(products / "include"),
    "-F", str(products), "-L", str(products),
    *map(str, sources),
    *[str(products / (name + ".o")) for name in ["DeviceGatewayAPI", "MinimuxerCommon", "ZIPFoundation"]],
    "-lz", "-o", str(runner),
], cwd=root, check=True)
sys.exit(subprocess.call([str(runner), *sys.argv[1:]], cwd=root))
