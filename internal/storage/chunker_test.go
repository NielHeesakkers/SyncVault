package storage

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"strings"
	"testing"
)

func TestChunker_FixedSizeSplitting(t *testing.T) {
	chunkSize := 4
	data := []byte("abcdefghij") // 10 bytes -> 3 chunks: 4, 4, 2
	c := NewChunker(chunkSize)
	chunks, err := c.Chunk(bytes.NewReader(data))
	if err != nil {
		t.Fatalf("Chunk error: %v", err)
	}
	if len(chunks) != 3 {
		t.Fatalf("expected 3 chunks, got %d", len(chunks))
	}
	if chunks[0].Size != 4 {
		t.Errorf("chunk 0 size = %d, want 4", chunks[0].Size)
	}
	if chunks[1].Size != 4 {
		t.Errorf("chunk 1 size = %d, want 4", chunks[1].Size)
	}
	if chunks[2].Size != 2 {
		t.Errorf("chunk 2 size = %d, want 2", chunks[2].Size)
	}
	// Verify indices.
	for i, ch := range chunks {
		if ch.Index != i {
			t.Errorf("chunk %d index = %d, want %d", i, ch.Index, i)
		}
	}
}

func TestChunker_DeterministicHashing(t *testing.T) {
	data := []byte("hello world this is a test")
	c := NewChunker(8)
	chunks1, _ := c.Chunk(bytes.NewReader(data))
	chunks2, _ := c.Chunk(bytes.NewReader(data))
	if len(chunks1) != len(chunks2) {
		t.Fatalf("chunk counts differ: %d vs %d", len(chunks1), len(chunks2))
	}
	for i := range chunks1 {
		if chunks1[i].Hash != chunks2[i].Hash {
			t.Errorf("chunk %d hash mismatch", i)
		}
	}
}

func TestChunker_DifferentDataDifferentHash(t *testing.T) {
	c := NewChunker(16)
	chunks1, _ := c.Chunk(strings.NewReader("data one"))
	chunks2, _ := c.Chunk(strings.NewReader("data two"))
	if chunks1[0].Hash == chunks2[0].Hash {
		t.Error("different data produced same hash")
	}
}

func TestChunker_HashCorrectness(t *testing.T) {
	data := []byte("exactlyfourteen!")
	c := NewChunker(len(data))
	chunks, err := c.Chunk(bytes.NewReader(data))
	if err != nil {
		t.Fatal(err)
	}
	if len(chunks) != 1 {
		t.Fatalf("expected 1 chunk, got %d", len(chunks))
	}
	h := sha256.Sum256(data)
	expected := hex.EncodeToString(h[:])
	if chunks[0].Hash != expected {
		t.Errorf("hash = %s, want %s", chunks[0].Hash, expected)
	}
}

func TestChunker_Reassembly(t *testing.T) {
	data := []byte("the quick brown fox jumps over the lazy dog")
	c := NewChunker(8)
	chunks, err := c.Chunk(bytes.NewReader(data))
	if err != nil {
		t.Fatal(err)
	}
	var reassembled []byte
	for _, ch := range chunks {
		reassembled = append(reassembled, ch.Data...)
	}
	if !bytes.Equal(reassembled, data) {
		t.Errorf("reassembled data does not match original")
	}
}

func TestChunker_EmptyInput(t *testing.T) {
	c := NewChunker(4)
	chunks, err := c.Chunk(bytes.NewReader(nil))
	if err != nil {
		t.Fatal(err)
	}
	if len(chunks) != 0 {
		t.Errorf("expected 0 chunks for empty input, got %d", len(chunks))
	}
}
