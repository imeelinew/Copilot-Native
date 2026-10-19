#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
python3 scripts/validate-project-knowledge.py
test_dir=$(mktemp -d /tmp/copilot-knowledge-tests.XXXXXX)
trap 'rm -rf "$test_dir"' EXIT
xcrun swiftc -swift-version 6 -parse-as-library \
  'Copilot Native/InterviewKnowledgeModels.swift' \
  'Copilot Native/InterviewKnowledgeEngine.swift' \
  'Copilot Native/ChatCompletionClient.swift' \
  'Copilot Native/RemoteAISettings.swift' \
  tests/InterviewKnowledgeTests.swift -o "$test_dir/test-interview-knowledge"
"$test_dir/test-interview-knowledge" "$PWD/Copilot Native/Resources/ProjectFacts.json" "$@"
