import Foundation
import HealthKit

extension TrioRemoteControl {
    func handleBolusCommand(_ payload: CommandPayload) async throws {
        guard let bolusAmount = payload.bolusAmount else {
            await logError("Command rejected: bolus amount is missing or invalid.", payload: payload)
            return
        }

        try await enactValidatedBolus(
            amount: bolusAmount,
            payload: payload,
            successNotificationMessage: "Bolus started"
        )
    }

    /// Runs a bolus amount through the shared safety checks and, if allowed, enacts it. Used both for an
    /// explicit remote bolus amount and for the auto-computed recommended bolus of a remote meal, so both
    /// go through the same `BolusSafetyValidator`, `enactBolus`, logging, and return-notification path.
    func enactValidatedBolus(
        amount: Decimal,
        payload: CommandPayload,
        successNotificationMessage: String
    ) async throws {
        let validation = try await bolusSafetyValidator.validate(
            bolusAmount: amount,
            lookbackStart: Date(timeIntervalSince1970: payload.timestamp)
        )

        switch validation {
        case .allowed:
            break
        case let .rejected(reason):
            await logError(reason.remoteCommandMessage(bolusAmount: amount), payload: payload)
            return
        }

        debug(.remoteControl, "Enacting bolus command with amount: \(amount) units.")

        guard let apsManager = await TrioApp.resolver.resolve(APSManager.self) else {
            await logError(
                "Error: unable to process bolus command because the APS Manager is not available.",
                payload: payload
            )
            return
        }

        if let returnInfo = payload.returnNotification {
            await RemoteNotificationResponseManager.shared.sendResponseNotification(
                to: returnInfo,
                commandType: payload.commandType,
                success: true,
                message: "Initiating bolus..."
            )
        }

        await apsManager
            .enactBolus(amount: Double(truncating: amount as NSNumber), isSMB: false) { [weak self] success, message in
                guard let self = self else { return }
                Task {
                    if success {
                        await self.logSuccess(
                            "Remote command processed successfully. \(payload.humanReadableDescription())",
                            payload: payload,
                            customNotificationMessage: successNotificationMessage
                        )
                    } else {
                        await self.logError(
                            message,
                            payload: payload
                        )
                    }
                }
            }
    }
}

private extension BolusSafetyRejection {
    func remoteCommandMessage(bolusAmount: Decimal) -> String {
        switch self {
        case let .exceedsMaxBolus(maxBolus):
            return "Command rejected: bolus amount (\(bolusAmount) units) exceeds the maximum allowed (\(maxBolus) units)."
        case .iobUnavailable:
            return "Command rejected: current IOB is not available."
        case let .exceedsMaxIOB(currentIOB, maxIOB):
            return "Command rejected: bolus amount (\(bolusAmount) units) would exceed max IOB (\(maxIOB) units). Current IOB: \(currentIOB) units."
        case .recentBolusWithinWindow:
            return "Command rejected: boluses totaling more than 20% of the requested amount have been delivered since the command was sent."
        }
    }
}
