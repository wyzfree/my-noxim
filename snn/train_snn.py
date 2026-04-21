#!/usr/bin/env python3
"""
Train a 2-layer ANN (784->256->10) on MNIST using pure numpy.
After training, weights are saved as .npy files for SNN inference.

ANN-to-SNN conversion strategy:
  - Train standard ANN with ReLU + softmax
  - At inference time, convert activations to spike rates (rate coding)
  - Neuron j fires at timestep t with probability proportional to its activation
"""
import os, numpy as np

DATA_DIR    = os.path.join(os.path.dirname(__file__), 'data')
WEIGHTS_DIR = os.path.join(os.path.dirname(__file__), 'weights')

# ---------- helpers ----------
def relu(x):        return np.maximum(0, x)
def relu_grad(x):   return (x > 0).astype(np.float32)
def softmax(x):
    e = np.exp(x - x.max(axis=1, keepdims=True))
    return e / e.sum(axis=1, keepdims=True)

def cross_entropy(pred, y):
    n = len(y)
    return -np.log(pred[np.arange(n), y] + 1e-9).mean()

def accuracy(pred, y):
    return (pred.argmax(axis=1) == y).mean()

# ---------- forward ----------
def forward(X, W1, b1, W2, b2):
    z1 = X @ W1 + b1        # (N, 256)
    a1 = relu(z1)
    z2 = a1 @ W2 + b2       # (N, 10)
    a2 = softmax(z2)
    return z1, a1, z2, a2

# ---------- backward ----------
def backward(X, y, z1, a1, z2, a2, W2):
    n = len(y)
    dz2 = a2.copy(); dz2[np.arange(n), y] -= 1; dz2 /= n
    dW2 = a1.T @ dz2
    db2 = dz2.sum(axis=0)
    da1 = dz2 @ W2.T
    dz1 = da1 * relu_grad(z1)
    dW1 = X.T @ dz1
    db1 = dz1.sum(axis=0)
    return dW1, db1, dW2, db2

# ---------- train ----------
def train(epochs=20, batch=128, lr=0.05, seed=42):
    rng = np.random.default_rng(seed)
    os.makedirs(WEIGHTS_DIR, exist_ok=True)

    # Load data
    X_tr = np.load(os.path.join(DATA_DIR, 'train_X.npy'))
    y_tr = np.load(os.path.join(DATA_DIR, 'train_y.npy'))
    X_te = np.load(os.path.join(DATA_DIR, 'test_X.npy'))
    y_te = np.load(os.path.join(DATA_DIR, 'test_y.npy'))

    # He initialization
    W1 = rng.standard_normal((784, 256)).astype(np.float32) * np.sqrt(2/784)
    b1 = np.zeros(256, dtype=np.float32)
    W2 = rng.standard_normal((256, 10)).astype(np.float32)  * np.sqrt(2/256)
    b2 = np.zeros(10,  dtype=np.float32)

    n = len(X_tr)
    best_acc = 0.0

    for ep in range(1, epochs+1):
        # shuffle
        idx = rng.permutation(n)
        X_tr, y_tr = X_tr[idx], y_tr[idx]

        # mini-batch SGD
        for i in range(0, n, batch):
            Xb, yb = X_tr[i:i+batch], y_tr[i:i+batch]
            z1, a1, z2, a2 = forward(Xb, W1, b1, W2, b2)
            dW1, db1, dW2, db2 = backward(Xb, yb, z1, a1, z2, a2, W2)
            W1 -= lr * dW1;  b1 -= lr * db1
            W2 -= lr * dW2;  b2 -= lr * db2

        # evaluate
        _, _, _, pred_te = forward(X_te, W1, b1, W2, b2)
        _, _, _, pred_tr = forward(X_tr[:2000], W1, b1, W2, b2)
        te_acc = accuracy(pred_te, y_te)
        tr_acc = accuracy(pred_tr, y_tr[:2000])
        loss   = cross_entropy(pred_te, y_te)
        print(f'Epoch {ep:2d}  train_acc={tr_acc:.4f}  test_acc={te_acc:.4f}  loss={loss:.4f}')

        if te_acc > best_acc:
            best_acc = te_acc
            np.save(os.path.join(WEIGHTS_DIR, 'W1.npy'), W1)
            np.save(os.path.join(WEIGHTS_DIR, 'b1.npy'), b1)
            np.save(os.path.join(WEIGHTS_DIR, 'W2.npy'), W2)
            np.save(os.path.join(WEIGHTS_DIR, 'b2.npy'), b2)

    print(f'\nBest test accuracy: {best_acc:.4f}')
    print(f'Weights saved to {WEIGHTS_DIR}/')

if __name__ == '__main__':
    train()
