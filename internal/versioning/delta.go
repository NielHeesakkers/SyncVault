package versioning

import (
	"bytes"
	"compress/gzip"
	"encoding/binary"
	"fmt"
	"io"
)

const (
	blockSize = 64

	opInsert = 0x01
	opCopy   = 0x02
)

// CreatePatch produces a gzip-compressed binary patch that transforms old into new.
// The patch is a stream of operations:
//
//	0x01 + uint32(len) + data  — INSERT literal bytes
//	0x02 + uint32(offset) + uint32(len) — COPY from old at offset
func CreatePatch(old, new []byte) ([]byte, error) {
	// Build block index: rolling hash of each blockSize-aligned chunk of old.
	type blockEntry struct {
		offset int
	}
	index := make(map[string]blockEntry, len(old)/blockSize+1)
	for i := 0; i+blockSize <= len(old); i += blockSize {
		key := string(old[i : i+blockSize])
		if _, exists := index[key]; !exists {
			index[key] = blockEntry{offset: i}
		}
	}

	var buf bytes.Buffer
	gz := gzip.NewWriter(&buf)

	insertBuf := make([]byte, 0, blockSize)

	flushInsert := func() error {
		if len(insertBuf) == 0 {
			return nil
		}
		hdr := [5]byte{opInsert}
		binary.BigEndian.PutUint32(hdr[1:], uint32(len(insertBuf)))
		if _, err := gz.Write(hdr[:]); err != nil {
			return err
		}
		if _, err := gz.Write(insertBuf); err != nil {
			return err
		}
		insertBuf = insertBuf[:0]
		return nil
	}

	emitCopy := func(offset, length int) error {
		hdr := [9]byte{opCopy}
		binary.BigEndian.PutUint32(hdr[1:5], uint32(offset))
		binary.BigEndian.PutUint32(hdr[5:9], uint32(length))
		_, err := gz.Write(hdr[:])
		return err
	}

	i := 0
	for i < len(new) {
		// Try to match a block starting at i.
		if i+blockSize <= len(new) {
			key := string(new[i : i+blockSize])
			if entry, ok := index[key]; ok {
				// Flush any pending insert bytes first.
				if err := flushInsert(); err != nil {
					return nil, fmt.Errorf("versioning: patch flush insert: %w", err)
				}

				// Extend match forward.
				oldOff := entry.offset
				matchLen := blockSize
				for i+matchLen < len(new) && oldOff+matchLen < len(old) &&
					new[i+matchLen] == old[oldOff+matchLen] {
					matchLen++
				}

				if err := emitCopy(oldOff, matchLen); err != nil {
					return nil, fmt.Errorf("versioning: patch emit copy: %w", err)
				}
				i += matchLen
				continue
			}
		}
		insertBuf = append(insertBuf, new[i])
		i++
	}

	if err := flushInsert(); err != nil {
		return nil, fmt.Errorf("versioning: patch flush final insert: %w", err)
	}
	if err := gz.Close(); err != nil {
		return nil, fmt.Errorf("versioning: patch gzip close: %w", err)
	}
	return buf.Bytes(), nil
}

// ApplyPatch reconstructs the new file by applying patch to old.
func ApplyPatch(old, patch []byte) ([]byte, error) {
	gr, err := gzip.NewReader(bytes.NewReader(patch))
	if err != nil {
		return nil, fmt.Errorf("versioning: apply patch gzip open: %w", err)
	}
	defer gr.Close()

	data, err := io.ReadAll(gr)
	if err != nil {
		return nil, fmt.Errorf("versioning: apply patch gzip read: %w", err)
	}

	var out bytes.Buffer
	pos := 0
	for pos < len(data) {
		op := data[pos]
		pos++
		switch op {
		case opInsert:
			if pos+4 > len(data) {
				return nil, fmt.Errorf("versioning: apply patch: truncated INSERT header")
			}
			length := int(binary.BigEndian.Uint32(data[pos : pos+4]))
			pos += 4
			if pos+length > len(data) {
				return nil, fmt.Errorf("versioning: apply patch: truncated INSERT data")
			}
			out.Write(data[pos : pos+length])
			pos += length

		case opCopy:
			if pos+8 > len(data) {
				return nil, fmt.Errorf("versioning: apply patch: truncated COPY header")
			}
			offset := int(binary.BigEndian.Uint32(data[pos : pos+4]))
			length := int(binary.BigEndian.Uint32(data[pos+4 : pos+8]))
			pos += 8
			if offset+length > len(old) {
				return nil, fmt.Errorf("versioning: apply patch: COPY out of bounds (offset=%d, len=%d, oldLen=%d)",
					offset, length, len(old))
			}
			out.Write(old[offset : offset+length])

		default:
			return nil, fmt.Errorf("versioning: apply patch: unknown op 0x%02x at pos %d", op, pos-1)
		}
	}
	return out.Bytes(), nil
}
