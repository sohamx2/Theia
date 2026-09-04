# Held-out screenshot benchmark

`ClassifierPipelineBenchmark` accepts the existing website-evaluation fields plus:

- `screenshotPath`: absolute path to a saved PNG or JPEG. OCR is run once before timing classification.
- `expectedSubcategory`: optional exact `IntentSubcategory` raw value.

Every selected case must contain a non-empty `screenshotPath` and the runner must receive
`--held-out-real-screenshots` before a model can become replacement-eligible. Synthetic
`ocrText` cases can exercise regressions but can never pass the replacement gate.

Run all five candidates with:

```bash
Tests/run_model_candidate_benchmarks.sh /tmp/TheiaClassifierPipelineBenchmark Tests/RealScreenshotBenchmark.json
```

The candidate runner enforces at least 99% parent-category accuracy and 99% valid prompt
JSON. It records exact subcategory, exact subject, and classification, prompt, and
end-to-end p50/p95 latency for every model.
