#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
test_dir=$(mktemp -d /tmp/copilot-screen-tests.XXXXXX)
trap 'rm -rf "$test_dir"' EXIT
xcrun swiftc -swift-version 6 -parse-as-library \
  'Copilot Native/ChatCompletionClient.swift' \
  'Copilot Native/RemoteAISettings.swift' \
  'Copilot Native/ScreenQuestionController.swift' \
  'Copilot Native/RegionScreenshotSelector.swift' \
  'Copilot Native/ScreenAnswerPanel.swift' \
  'Copilot Native/MarkdownDocumentView.swift' \
  tests/ScreenQuestionClientTests.swift -o "$test_dir/test-screen-questions"
"$test_dir/test-screen-questions" "$@"
