import Foundation

extension TrioRemoteControl {
    func handleMealCommand(_ payload: CommandPayload) async throws {
        guard payload.carbs != nil || payload.fat != nil || payload.protein != nil else {
            await logError("Command rejected: meal data is incomplete or invalid.", payload: payload)
            return
        }

        let carbsDecimal = payload.carbs != nil ? Decimal(payload.carbs!) : nil
        let fatDecimal = payload.fat != nil ? Decimal(payload.fat!) : nil
        let proteinDecimal = payload.protein != nil ? Decimal(payload.protein!) : nil

        let settings = await TrioApp.resolver.resolve(SettingsManager.self)?.settings
        let maxCarbs = settings?.maxCarbs ?? Decimal(0)
        let maxFat = settings?.maxFat ?? Decimal(0)
        let maxProtein = settings?.maxProtein ?? Decimal(0)

        if let carbs = carbsDecimal, carbs > maxCarbs {
            await logError(
                "Command rejected: carbs amount (\(carbs)g) exceeds the maximum allowed (\(maxCarbs)g).",
                payload: payload
            )
            return
        }
        if let fat = fatDecimal, fat > maxFat {
            await logError("Command rejected: fat amount (\(fat)g) exceeds the maximum allowed (\(maxFat)g).", payload: payload)
            return
        }
        if let protein = proteinDecimal, protein > maxProtein {
            await logError(
                "Command rejected: protein amount (\(protein)g) exceeds the maximum allowed (\(maxProtein)g).",
                payload: payload
            )
            return
        }

        let payloadDate = Date(timeIntervalSince1970: payload.timestamp)
        let taskContext = CoreDataStack.shared.newTaskContext()
        let results = try await CoreDataStack.shared.fetchEntitiesAsync(
            ofType: CarbEntryStored.self, onContext: taskContext, predicate: NSPredicate(
                format: "date > %@",
                payloadDate as NSDate
            ), key: "date", ascending: false
        )

        let hasNewerCarbEntries = await taskContext.perform {
            (results as? [CarbEntryStored])?.isEmpty == false
        }
        if hasNewerCarbEntries {
            await logError(
                "Command rejected: newer carb entries have been logged since the command was sent.",
                payload: payload
            )
            return
        }

        let actualDate = payload.scheduledTime.map { Date(timeIntervalSince1970: $0) }

        let mealEntry = CarbsEntry(
            id: UUID().uuidString, createdAt: Date(), actualDate: actualDate,
            carbs: carbsDecimal ?? 0, fat: fatDecimal, protein: proteinDecimal,
            note: "Remote meal command", enteredBy: CarbsEntry.local, isFPU: false,
            fpuID: fatDecimal ?? 0 > 0 || proteinDecimal ?? 0 > 0 ? UUID().uuidString : nil
        )

        // Decide on any follow-up bolus BEFORE storing the meal. Computing the recommended dose first
        // matches the Treatments UI's compute-then-save order and avoids a window in which the just-stored
        // carbs could be counted twice (once explicitly, once via COB) had a determination run in between.
        let bolusPlan = await resolveMealBolusPlan(payload, carbs: carbsDecimal ?? 0, mealDate: actualDate)

        // Store the meal. If this throws, the command fails and no bolus is enacted.
        try await carbsStorage.storeCarbs([mealEntry], areFetchedFromRemote: false)

        // The meal is stored. Carry out the bolus plan.
        switch bolusPlan {
        case .none:
            await logSuccess(
                "Remote command processed successfully. \(payload.humanReadableDescription())",
                payload: payload,
                customNotificationMessage: "Meal logged"
            )

        case .explicit:
            try await handleBolusCommand(payload)

        case let .reject(reason):
            await logError(reason, payload: payload)

        case let .skip(reason):
            // The meal was stored on purpose without a bolus. Report success (with a Nightscout note) so the
            // caregiver is told what happened rather than shown a failure.
            await logSuccess(reason, payload: payload, customNotificationMessage: reason, uploadNote: true)

        case let .recommended(amount):
            do {
                try await enactValidatedBolus(
                    amount: amount,
                    payload: payload,
                    successNotificationMessage: "Auto-bolus started: \(amount) U"
                )
            } catch {
                await logError(
                    "Auto-bolus failed after the meal was stored: \(error.localizedDescription). The meal was logged, but no insulin was delivered by this command.",
                    payload: payload
                )
            }
        }
    }

    /// The follow-up-bolus decision for a remote meal, resolved before the meal is stored.
    private enum MealBolusPlan {
        /// No bolus was requested.
        case none
        /// An explicit bolus amount was provided; enact it through the existing bolus path.
        case explicit
        /// A genuine rejection; surfaced to the caregiver as a failure notification.
        case reject(String)
        /// The meal is stored but no auto-bolus is given for a benign reason; surfaced as success.
        case skip(String)
        /// Enact this auto-computed, safety-clamped recommended amount.
        case recommended(Decimal)
    }

    /// Tolerances that decide whether a remote meal is happening "now" and therefore eligible for an
    /// auto-bolus. Meals sent for "now" carry no `scheduledTime`, so this only affects explicitly
    /// scheduled meals. The overall command is already rejected upstream if older than 600s.
    private enum AutoBolusMealScheduling {
        /// Meals timed more than this far in the future are stored without bolusing (an upfront bolus for
        /// food not yet eaten is unsafe). Mirrors the 600s command-freshness window.
        static let futureTolerance: TimeInterval = 10 * 60
        /// Meals backdated more than this far into the past are stored without bolusing: the loop and its
        /// SMBs will account for the carbs, so an upfront bolus for old carbs would over-deliver. The
        /// Treatments UI treats any deviation from "now" as backdated; remote commands use a wider window
        /// to absorb push-delivery latency and minute-granularity scheduling.
        static let pastTolerance: TimeInterval = 10 * 60
    }

    /// Resolves what to do about a bolus for a remote meal. Called before the meal is stored so the
    /// recommended-bolus calculation sees the same COB the Treatments UI would (the just-stored entry is
    /// not yet reflected in the latest determination).
    private func resolveMealBolusPlan(_ payload: CommandPayload, carbs: Decimal, mealDate: Date?) async -> MealBolusPlan {
        let wantsRecommendedBolus = payload.useRecommendedBolus == true
        let hasExplicitBolus = payload.bolusAmount != nil

        // Defense against malformed senders: an explicit amount and a recommended bolus are mutually
        // exclusive. The meal is still stored, but no bolus is given.
        if hasExplicitBolus, wantsRecommendedBolus {
            return .reject(
                "Command rejected: a meal cannot request both an explicit bolus amount and Trio's recommended bolus. The meal was logged, but no bolus was given."
            )
        }
        if hasExplicitBolus {
            return .explicit
        }
        guard wantsRecommendedBolus else {
            return .none
        }

        guard UserDefaults.standard.bool(forKey: "isRemoteMealAutoBolusEnabled") else {
            return .skip(
                "The meal was logged. Auto-bolus was not given because \"Auto-bolus for Remote Meals\" is disabled in Trio's Remote Control settings."
            )
        }

        // Gate on the meal's timing. A meal sent for "now" has no scheduledTime, so mealDate is nil.
        let now = Date()
        let mealTime = mealDate ?? now
        let offset = mealTime.timeIntervalSince(now)

        if offset > AutoBolusMealScheduling.futureTolerance {
            return .skip(
                "The meal was logged. Auto-bolus was skipped because the meal is scheduled in the future; enact a bolus when the meal is eaten."
            )
        }
        if offset < -AutoBolusMealScheduling.pastTolerance {
            return .skip(
                "The meal was logged. Auto-bolus was skipped because the meal is backdated; the loop is already accounting for these carbs, so no upfront bolus was given."
            )
        }

        guard let apsManager = await TrioApp.resolver.resolve(APSManager.self),
              let bolusCalculationManager = await TrioApp.resolver.resolve(BolusCalculationManager.self)
        else {
            return .reject(
                "Error: unable to compute the recommended bolus because required services are not available. The meal was logged, but no bolus was given."
            )
        }

        // Mirror how the Treatments UI drives the calculator for a fresh (non-backdated) entry: pass the
        // meal's carbs explicitly and let the calculator self-load IOB/COB/BG/ISF/CR/target from the latest
        // determination. `minPredBG: nil` uses the latest determination's minimum predicted glucose, the
        // conservative choice here.
        let result = await bolusCalculationManager.handleBolusCalculation(
            carbs: carbs,
            useFattyMealCorrection: false,
            useSuperBolus: false,
            lastLoopDate: apsManager.lastLoopDate,
            minPredBG: nil,
            simulatedCOB: nil,
            isBackdated: false
        )

        // `insulinCalculated` is already clamped to 0 when glucose or the minimum prediction is below the
        // safety threshold, when the loop is stale, or when IOB/maxBolus limits leave no room, and is
        // rounded to the pump increment.
        let recommendedBolus = result.insulinCalculated
        guard recommendedBolus > 0 else {
            return .skip(
                "The meal was logged. Auto-bolus recommended no insulin for this meal. This is expected when glucose or a prediction is below the safety limit, the loop is stale, or IOB is already at its limit."
            )
        }

        return .recommended(recommendedBolus)
    }
}
