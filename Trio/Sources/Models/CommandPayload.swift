import Foundation

struct EncryptedPushMessage: Decodable {
    let encryptedData: String

    enum CodingKeys: String, CodingKey {
        case encryptedData = "encrypted_data"
    }
}

struct CommandPayload: Decodable, Sendable {
    var user: String
    var commandType: TrioRemoteControl.CommandType
    var timestamp: TimeInterval
    var bolusAmount: Decimal?
    var target: Int?
    var duration: Int?
    var carbs: Int?
    var protein: Int?
    var fat: Int?
    var overrideName: String?
    var scheduledTime: TimeInterval?
    var useRecommendedBolus: Bool?
    var returnNotification: ReturnNotificationInfo?

    struct ReturnNotificationInfo: Decodable, Sendable {
        let productionEnvironment: Bool
        let deviceToken: String
        let bundleId: String
        let teamId: String
        let keyId: String
        let apnsKey: String

        enum CodingKeys: String, CodingKey {
            case productionEnvironment = "production_environment"
            case deviceToken = "device_token"
            case bundleId = "bundle_id"
            case teamId = "team_id"
            case keyId = "key_id"
            case apnsKey = "apns_key"
        }
    }

    enum CodingKeys: String, CodingKey {
        case user
        case timestamp
        case target
        case duration
        case carbs
        case protein
        case fat
        case overrideName
        case commandType = "command_type"
        case bolusAmount = "bolus_amount"
        case scheduledTime = "scheduled_time"
        case useRecommendedBolus = "use_recommended_bolus"
        case returnNotification = "return_notification"
    }

    func humanReadableDescription() -> String {
        var description = "User: \(user). Command Type: \(commandType.description). "

        if let override = overrideName {
            description += "Override Name: \(override). "
        }

        switch commandType {
        case .bolus:
            if let amount = bolusAmount {
                description += "Bolus Amount: \(amount) units."
            } else {
                description += "Bolus Amount: unknown."
            }
        case .tempTarget:
            let targetDesc = target != nil ? "\(target!) mg/dL" : "unknown target"
            let durationDesc = duration != nil ? "\(duration!) minutes" : "unknown duration"
            description += "Temp Target: \(targetDesc), Duration: \(durationDesc)."
        case .cancelTempTarget:
            description += "Cancel Temp Target command."
        case .meal:
            let carbsDesc = carbs != nil ? "\(carbs!)g carbs" : "unknown carbs"
            let fatDesc = fat != nil ? "\(fat!)g fat" : "unknown fat"
            let proteinDesc = protein != nil ? "\(protein!)g protein" : "unknown protein"
            description += "Meal with \(carbsDesc), \(fatDesc), \(proteinDesc)."
            if useRecommendedBolus == true {
                description += " Auto-bolus: recommended."
            }
        case .startOverride:
            if let override = overrideName {
                description += "Start Override: \(override)."
            } else {
                description += "Start Override: unknown override name."
            }
        case .cancelOverride:
            description += "Cancel Override command."
        }

        if let scheduledTime = scheduledTime {
            let date = Date(timeIntervalSince1970: scheduledTime)
            let formatter = DateFormatter()
            formatter.dateStyle = .short
            formatter.timeStyle = .short
            let dateString = formatter.string(from: date)
            description += " Scheduled for: \(dateString)."
        }

        return description
    }
}

extension TrioRemoteControl {
    enum CommandType: String, Codable {
        case bolus
        case tempTarget = "temp_target"
        case cancelTempTarget = "cancel_temp_target"
        case meal
        case startOverride = "start_override"
        case cancelOverride = "cancel_override"

        var description: String {
            switch self {
            case .bolus:
                return "Bolus"
            case .tempTarget:
                return "Temporary Target"
            case .cancelTempTarget:
                return "Cancel Temporary Target"
            case .meal:
                return "Meal"
            case .startOverride:
                return "Start Override"
            case .cancelOverride:
                return "Cancel Override"
            }
        }
    }
}

/// How Trio reacts to a remote meal that requests Trio's recommended bolus.
enum RemoteMealBolusMode: String, CaseIterable, Identifiable {
    /// No automatic bolus. The meal is stored; a recommended-bolus request is acknowledged with a note.
    case off
    /// Trio computes the recommended bolus and sends it back to Loop Follow for the caregiver to review and
    /// confirm. Trio does not dose on its own.
    case requireReview
    /// Trio computes the recommended bolus and enacts it directly through its own bolus calculator and
    /// safety limits.
    case auto

    var id: String { rawValue }

    /// UserDefaults key holding the raw value.
    static let storageKey = "remoteMealBolusMode"

    /// Legacy boolean key; `true` meant auto-bolus was enabled.
    private static let legacyEnabledKey = "isRemoteMealAutoBolusEnabled"

    /// The configured mode, migrating the legacy boolean the first time no explicit mode has been stored.
    static func current(from defaults: UserDefaults = .standard) -> RemoteMealBolusMode {
        if let raw = defaults.string(forKey: storageKey), let mode = RemoteMealBolusMode(rawValue: raw) {
            return mode
        }
        return defaults.bool(forKey: legacyEnabledKey) ? .auto : .off
    }

    var displayName: String {
        switch self {
        case .off:
            return String(localized: "Off")
        case .requireReview:
            return String(localized: "Require Review")
        case .auto:
            return String(localized: "Auto")
        }
    }
}
