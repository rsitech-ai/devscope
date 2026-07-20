#if canImport(FoundationModels)
  import FoundationModels

  @available(macOS 26.0, *)
  extension GenerationOptions {
    static func devScopeGreedy(maximumResponseTokens: Int) -> Self {
      #if compiler(>=6.4)
        Self(
          samplingMode: .greedy,
          temperature: 0.0,
          maximumResponseTokens: maximumResponseTokens
        )
      #else
        Self(
          sampling: .greedy,
          temperature: 0.0,
          maximumResponseTokens: maximumResponseTokens
        )
      #endif
    }
  }
#endif
