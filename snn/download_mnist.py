#!/usr/bin/env python3
"""
Download and preprocess MNIST dataset into numpy arrays.
Saves to snn/data/{train_X,train_y,test_X,test_y}.npy
"""
import os, gzip, struct, urllib.request
import numpy as np

DATA_DIR = os.path.join(os.path.dirname(__file__), 'data')

MIRRORS = [
    'https://storage.googleapis.com/cvdf-datasets/mnist/',
    'http://yann.lecun.com/exdb/mnist/',
]

FILES = {
    'train_images': 'train-images-idx3-ubyte.gz',
    'train_labels': 'train-labels-idx1-ubyte.gz',
    'test_images':  't10k-images-idx3-ubyte.gz',
    'test_labels':  't10k-labels-idx1-ubyte.gz',
}

def download_file(fname, dest):
    for base in MIRRORS:
        try:
            url = base + fname
            print(f'  Trying {url} ...')
            urllib.request.urlretrieve(url, dest)
            print(f'  OK')
            return
        except Exception as e:
            print(f'  Failed: {e}')
    raise RuntimeError(f'Cannot download {fname} from any mirror')

def load_images(path):
    with gzip.open(path, 'rb') as f:
        magic, n, rows, cols = struct.unpack('>IIII', f.read(16))
        data = np.frombuffer(f.read(), dtype=np.uint8)
    return data.reshape(n, rows * cols).astype(np.float32) / 255.0

def load_labels(path):
    with gzip.open(path, 'rb') as f:
        magic, n = struct.unpack('>II', f.read(8))
        return np.frombuffer(f.read(), dtype=np.uint8)

def download_mnist():
    os.makedirs(DATA_DIR, exist_ok=True)
    out = {}
    for key, fname in FILES.items():
        dest = os.path.join(DATA_DIR, fname)
        if not os.path.exists(dest):
            print(f'Downloading {fname}...')
            download_file(fname, dest)
        out[key] = dest

    train_X = load_images(out['train_images'])
    train_y = load_labels(out['train_labels'])
    test_X  = load_images(out['test_images'])
    test_y  = load_labels(out['test_labels'])

    np.save(os.path.join(DATA_DIR, 'train_X.npy'), train_X)
    np.save(os.path.join(DATA_DIR, 'train_y.npy'), train_y)
    np.save(os.path.join(DATA_DIR, 'test_X.npy'),  test_X)
    np.save(os.path.join(DATA_DIR, 'test_y.npy'),  test_y)

    print(f'Train: {train_X.shape}  Test: {test_X.shape}')
    return train_X, train_y, test_X, test_y

if __name__ == '__main__':
    download_mnist()
