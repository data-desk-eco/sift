import ArgumentParser
import SiftCore

/// AsyncParsableCommand specialisation that funnels every thrown error
/// through `reportSiftError` — printing the `[ERROR]    msg / → suggestion`
/// envelope on stderr — and exits non-zero. Conformers implement
/// `execute()` instead of `run()`.
///
/// The dispatch chain: ArgumentParser calls `run()`, the protocol's
/// default forwards to `execute()`, and any throw is caught here so each
/// subcommand body stays focused on the actual work.
protocol SiftSubcommand: AsyncParsableCommand {
    func execute() async throws
}

extension SiftSubcommand {
    func run() async throws {
        do {
            try await execute()
        } catch let exit as ExitCode {
            throw exit
        } catch {
            throw ExitCode(reportSiftError(error))
        }
    }
}
