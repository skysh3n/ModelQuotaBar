import Foundation

// 测试入口。跑法见 scripts/test.sh。
exit(TestRunner.run([
    QwenTokenPlanParsingTests.suite,
    ConsoleGatewayTests.suite,
    JSONSearchTests.suite,
    CredentialFieldTests.suite,
    QuotaWindowTests.suite,
    SharedStoreTests.suite,
    DeepSeekTests.suite,
    CursorTests.suite,
    WidgetSourceTests.suite,
]))