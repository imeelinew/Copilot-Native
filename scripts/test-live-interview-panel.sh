#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
test_dir=$(mktemp -d /tmp/copilot-live-panel-tests.XXXXXX)
trap 'rm -rf "$test_dir"' EXIT
xcrun swiftc -swift-version 6 -parse-as-library \
  'Copilot Native/LiveInterviewPanel.swift' \
  'Copilot Native/LiveInterviewController.swift' \
  'Copilot Native/LiveInterviewView.swift' \
  'Copilot Native/ScreenQuestionController.swift' \
  'Copilot Native/ScreenAnswerPanel.swift' \
  'Copilot Native/MarkdownDocumentView.swift' \
  'Copilot Native/InterviewKnowledgeModels.swift' \
  'Copilot Native/InterviewKnowledgeEngine.swift' \
  'Copilot Native/InterviewKnowledgeView.swift' \
  'Copilot Native/InterviewQuestionExtractor.swift' \
  'Copilot Native/AIAnswerController.swift' \
  'Copilot Native/SpeechSettings.swift' \
  'Copilot Native/SpeechAudioCapture.swift' \
  'Copilot Native/DoubaoSpeechConnection.swift' \
  'Copilot Native/ChatCompletionClient.swift' \
  'Copilot Native/RemoteAISettings.swift' \
  tests/LiveInterviewPanelTests.swift -o "$test_dir/test-live-interview-panel"
"$test_dir/test-live-interview-panel"
