package storage

import (
	"crypto/sha256"
	"encoding/hex"
	"io"
)

// Chunk represents a single chunk of a file.
type Chunk struct {
	Hash  string
	Data  []byte
	Size  int
	Index int
}

// Chunker splits an io.Reader into fixed-size chunks and computes SHA-256 hashes.
type Chunker struct {
	chunkSize int
}

// NewChunker returns a new Chunker with the given chunk size in bytes.
func NewChunker(chunkSize int) *Chunker {
	return &Chunker{chunkSize: chunkSize}
}

// Chunk reads all data from r and returns a slice of Chunks.
// Each chunk is at most chunkSize bytes. The last chunk may be smaller.
func (c *Chunker) Chunk(r io.Reader) ([]Chunk, error) {
	var chunks []Chunk
	index := 0
	buf := make([]byte, c.chunkSize)

	for {
		n, err := io.ReadFull(r, buf)
		if n > 0 {
			data := make([]byte, n)
			copy(data, buf[:n])

			h := sha256.Sum256(data)
			chunk := Chunk{
				Hash:  hex.EncodeToString(h[:]),
				Data:  data,
				Size:  n,
				Index: index,
			}
			chunks = append(chunks, chunk)
			index++
		}
		if err == io.EOF || err == io.ErrUnexpectedEOF {
			break
		}
		if err != nil {
			return nil, err
		}
	}

	return chunks, nil
}
