import Foundation
import XCTest
@testable import Pop

final class CloudServicePresetTests: XCTestCase {
    func testBundledAIConfigurationsRequirePersonalKeysAndStartDisabled() throws {
        let services = AppPreferences().services
        XCTAssertEqual(services.prefix(2).map { $0.options["provider"] }, ["zhipu", "siliconflow"])
        for service in services.prefix(2) {
            XCTAssertFalse(service.enabled)
            XCTAssertTrue(CloudServiceCatalog.requiresPersonalKey(for: service))
            XCTAssertTrue(CloudServiceCatalog.secretFields(for: service.kind, options: service.options).first?.required == true)
            XCTAssertTrue(CloudServiceCatalog.modelPresets(for: service).contains { $0.id == service.model })
            XCTAssertNotNil(CloudServiceCatalog.configurationURL(for: service))
            let endpoint = try HTTPTranslationService().endpointURL(service)
            XCTAssertTrue(endpoint.path.hasSuffix("/chat/completions"))
        }
        XCTAssertTrue(services.first { $0.kind == .apple && $0.capability == "translate" }?.enabled == true)
        XCTAssertTrue(services.first { $0.kind == .dictionary }?.enabled == true)
    }

    func testExistingProviderIdentityAndCustomConfigurationSurviveOneTimeMigration() throws {
        var existing = ServiceConfig(name: "My paid SiliconFlow", kind: .openAI)
        existing.enabled = true
        existing.endpoint = "https://api.siliconflow.cn/v1"
        existing.model = "my-account-model"
        existing.options = ["provider": "siliconflow", "mode": "custom", "userPrompt": "Keep this"]
        var migrated = try decodeLegacy([existing])
        XCTAssertEqual(migrated.services.first { $0.id == existing.id }, existing)
        XCTAssertEqual(migrated.services.first?.options["provider"], "zhipu")
        XCTAssertEqual(migrated.services.filter { $0.options["provider"] == "siliconflow" }.count, 1)
        XCTAssertEqual(migrated.services.filter { $0.options["provider"] == "zhipu" }.count, 1)
        XCTAssertFalse(try XCTUnwrap(migrated.services.first { $0.options["provider"] == "zhipu" }).enabled)
        migrated.services.removeAll { $0.options["provider"] == "zhipu" }
        let reloaded = try JSONDecoder().decode(AppPreferences.self, from: JSONEncoder().encode(migrated))
        XCTAssertEqual(reloaded, migrated)
        XCTAssertFalse(reloaded.services.contains { $0.options["provider"] == "zhipu" })
    }

    func testLegacyOfficialEndpointWithoutProviderIsNotDuplicatedOrMutated() throws {
        var existing = ServiceConfig(name: "My existing model", kind: .openAI)
        existing.endpoint = "https://open.bigmodel.cn/api/paas/v4/chat/completions"
        existing.model = "my-model"
        existing.enabled = true
        let migrated = try decodeLegacy([existing])
        XCTAssertEqual(migrated.services.first, existing)
        XCTAssertFalse(migrated.services.contains { $0.options["provider"] == "zhipu" })
        XCTAssertEqual(migrated.services.filter { $0.options["provider"] == "siliconflow" }.count, 1)
    }

    func testLegacyOfficialEndpointsRecoverConfigurationMetadataWithoutMutation() {
        for (endpoint, provider) in [("https://open.bigmodel.cn/api/paas/v4", "zhipu"), ("https://api.siliconflow.cn/v1", "siliconflow")] {
            let legacy = ServiceConfig(name: "My existing name", kind: .openAI, endpoint: endpoint, model: "custom-model")
            XCTAssertEqual(CloudServiceCatalog.configurationProvider(for: legacy), provider)
            XCTAssertFalse(CloudServiceCatalog.modelPresets(for: legacy).isEmpty)
            XCTAssertTrue(CloudServiceCatalog.requiresPersonalKey(for: legacy))
            XCTAssertNotNil(CloudServiceCatalog.configurationURL(for: legacy))
            XCTAssertTrue(CloudServiceCatalog.configurationHint(for: legacy).contains("自己的"))
            XCTAssertTrue(legacy.options.isEmpty)
            var explicit = legacy
            explicit.options["provider"] = "openai"
            XCTAssertEqual(CloudServiceCatalog.configurationProvider(for: explicit), "openai")
            var otherKind = legacy
            otherKind.kind = .gemini
            XCTAssertNil(CloudServiceCatalog.configurationProvider(for: otherKind))
        }
        let lookalike = ServiceConfig(name: "Untrusted host", kind: .openAI, endpoint: "https://api.siliconflow.cn.example.com/v1")
        XCTAssertNil(CloudServiceCatalog.configurationProvider(for: lookalike))
    }

    private func decodeLegacy(_ services: [ServiceConfig]) throws -> AppPreferences {
        let values = try JSONSerialization.jsonObject(with: JSONEncoder().encode(services))
        return try JSONDecoder().decode(AppPreferences.self, from: JSONSerialization.data(withJSONObject: ["services": values, "dictionaryServiceConfigurationVersion": 1, "ocrServiceConfigurationVersion": 3]))
    }
}
