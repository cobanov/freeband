import BackgroundTasks
import Combine
import Foundation
import SwiftData
import SwiftUI
import UIKit
import UserNotifications

/// Adding and removing bands and their keys, and deleting everything.
@MainActor
extension AppModel {
    // MARK: keys

    /// Adds one band per MAC for the chosen keys, or adds the keys to a band already added.
    /// Keys that worked before stay first; new ones are tried after them.
    @discardableResult
    func add(keys: [BandKey]) -> [Band] {
        guard !isDemo else { return [] }
        var bands = (try? context.fetch(FetchDescriptor<Band>())) ?? []
        var result: [Band] = []
        for group in BandKey.groupedByBand(keys) {
            let lead = group[0]
            let match = bands.first { band in
                if let a = band.macSuffix, let b = lead.macSuffix { return a == b }
                return band.name == lead.name.trimmingCharacters(in: .whitespaces)
            }
            let band = match ?? Band(name: BandKey.bestName(group), mac: lead.mac)
            if match == nil {
                context.insert(band)
                bands.append(band)
            } else if BandKey.bestName(group).localizedCaseInsensitiveContains("pro"), !band.name.localizedCaseInsensitiveContains("pro") {
                band.name = BandKey.bestName(group)
                band.model = Band.modelCode(for: band.name)
            }
            Vault.setBandKeys(Vault.bandKeys(band.id) + group.map(\.hex), for: band.id)
            if !result.contains(where: { $0.id == band.id }) { result.append(band) }
        }
        try? context.save()
        return result
    }

    /// Removes the band with everything stored for it: samples, raw files, derived rows, scores.
    @discardableResult func remove(_ band: Band) -> Bool {
        do { try healthExport.suppressHistory(); dataDeletionError = nil }
        catch { dataDeletionError = String(localized: "Could not safely delete local data. Try again."); return false }
        let id = band.id
        Vault.removeBandKey(id)
        try? context.delete(model: Sample.self, where: #Predicate { $0.bandID == id })
        try? context.delete(model: ActivityBlob.self, where: #Predicate { $0.bandID == id })
        ActivityIngest.deleteDerived(context: context, bandID: id, includingScores: true)
        pendingRollup[id] = nil
        monitoring = monitoring.filter { !$0.key.hasPrefix(id.uuidString) }
        context.delete(band)
        try? context.save()
        updateHold()
        return true
    }

    /// Deletes every observation, raw file, derived row and score; bands, keys and webhooks stay.
    func deleteAllData() {
        do { try healthExport.suppressHistory(); dataDeletionError = nil }
        catch { dataDeletionError = String(localized: "Could not safely delete local data. Try again."); return }
        try? context.delete(model: Sample.self)
        try? context.delete(model: ActivityBlob.self)
        ActivityIngest.deleteDerived(context: context, bandID: nil, includingScores: true)
        pendingRollup = [:]
        try? context.save()
        setCalibration(nil)
    }
}
