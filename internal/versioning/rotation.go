package versioning

import (
	"sort"
	"time"
)

// VersionInfo holds the minimal information needed for rotation decisions.
type VersionInfo struct {
	ID        string
	Num       int
	CreatedAt time.Time
}

// FIFO returns the versions that should be deleted (oldest first) when the
// total count exceeds maxVersions. Returns nil if the count is at or below
// the limit.
func FIFO(versions []VersionInfo, maxVersions int) []VersionInfo {
	if len(versions) <= maxVersions {
		return nil
	}

	// Sort oldest first by Num (ascending).
	sorted := make([]VersionInfo, len(versions))
	copy(sorted, versions)
	sort.Slice(sorted, func(i, j int) bool {
		return sorted[i].Num < sorted[j].Num
	})

	excess := len(versions) - maxVersions
	return sorted[:excess]
}

// Intelliversioning returns the versions that should be deleted to bring the
// count down to maxVersions. It removes versions that are closest together
// in time, preserving temporal diversity. The first and last versions are
// never deleted. Returns nil if the count is at or below the limit.
func Intelliversioning(versions []VersionInfo, maxVersions int) []VersionInfo {
	if len(versions) <= maxVersions {
		return nil
	}

	// Work on a mutable copy sorted by CreatedAt.
	pool := make([]VersionInfo, len(versions))
	copy(pool, versions)
	sort.Slice(pool, func(i, j int) bool {
		return pool[i].CreatedAt.Before(pool[j].CreatedAt)
	})

	var toDelete []VersionInfo

	for len(pool) > maxVersions {
		if len(pool) <= 2 {
			// Cannot delete first or last — nothing more to do.
			break
		}

		// Find the interior index (1 .. len-2) where the sum of the gaps to
		// its neighbours is smallest.
		bestIdx := -1
		bestGap := time.Duration(1<<63 - 1) // max duration

		for i := 1; i < len(pool)-1; i++ {
			gap := pool[i+1].CreatedAt.Sub(pool[i-1].CreatedAt)
			if gap < bestGap {
				bestGap = gap
				bestIdx = i
			}
		}

		if bestIdx == -1 {
			break
		}

		toDelete = append(toDelete, pool[bestIdx])
		pool = append(pool[:bestIdx], pool[bestIdx+1:]...)
	}

	return toDelete
}
