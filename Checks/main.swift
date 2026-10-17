import ClawdCoreChecks
import Foundation

do {
    print("Passed \(try CoreChecks.run()) core checks.")
} catch {
    print("Core checks failed: \(error)")
    exit(1)
}
