import numpy as np

from rehab.metrics import evaluate


def test_agreement_balanced_accuracy_and_baseline():
    labels = np.array([1, 1, 1, 1, 0, 0, 1, 0])
    predicted = np.array([1, 1, 1, 0, 0, 1, 1, 0])
    exercises = np.array([0, 0, 0, 0, 0, 0, 1, 1])
    result = evaluate(labels, predicted, exercises, ["a", "b"])
    assert result["agreement"] == 6 / 8
    # Correct ones: 4 of 5 found; incorrect ones: 2 of 3.
    assert result["balanced_accuracy"] == (4 / 5 + 2 / 3) / 2
    assert result["by_exercise"]["b"]["agreement"] == 1.0
    assert result["confusion"]["incorrect_called_correct"] == 1
    assert result["majority_baseline_agreement"] == 5 / 8
    assert result["meets_target"] is False


def test_always_saying_correct_cannot_look_good():
    labels = np.array([1] * 9 + [0])
    result = evaluate(labels, np.ones(10), np.zeros(10), ["a"])
    assert result["agreement"] == 0.9
    assert result["balanced_accuracy"] == 0.5
