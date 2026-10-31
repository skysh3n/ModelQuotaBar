import Foundation

// 测试入口。跑法见 scripts/test.sh。
exit(TestRunner.run([
    QwenTokenPlanParsingTests.suite,
    ConsoleGatewayTests.suite,
    JSONSearchTests.suite,
    CredentialFieldTests.suite,
    QuotaWindowTests.suite,
    SharedStoreTests.suite,
    AppSettingsTests.suite,
    DeepSeekTests.suite,
    CursorTests.suite,
    WidgetSourceTests.suite,
    ProviderMetadataTests.suite,
    CursorRegressionTests.suite,
    CredentialStoreTests.suite,
    QuotaStorePolicyTests.suite,
    QuotaFetcherSelectionTests.suite,
    QuotaFetcherMissingCredentialTests.suite,
    SharedStoreExtraTests.suite,
    QwenExtraTests.suite,
    CursorExtraTests.suite,
    AliyunErrorTests.suite,
    ProviderModelTests.suite,
    DeepSeekNetworkTests.suite,
    AliyunGatewayNetworkTests.suite,
]))