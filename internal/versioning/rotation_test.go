package versioning

import (
	"testing"
	"time"
)

// makeVersions creates n VersionInfo entries starting at startTime, spaced by interval.
func makeVersions(n int, startTime time.Time, interval time.Duration) []VersionInfo {
	vs := make([]VersionInfo, n)
	for i := range vs {
		vs[i] = VersionInfo{
			ID:        string(rune('A' + i)),
			Num:       i + 1,
			CreatedAt: startTime.Add(time.Duration(i) * interval),
		}
	}
	return vs
}

// --- FIFO tests ---

func TestFIFO_UnderLimit(t *testing.T) {
	versions := makeVersions(3, time.Now(), time.Hour)
	toDelete := FIFO(versions, 5)
	if toDelete != nil {
		t.Errorf("expected nil (under limit), got %v", toDelete)
	}
}

func TestFIFO_AtLimit(t *testing.T) {
	versions := makeVersions(5, time.Now(), time.Hour)
	toDelete := FIFO(versions, 5)
	if toDelete != nil {
		t.Errorf("expected nil (at limit), got %v", toDelete)
	}
}

func TestFIFO_OverLimit(t *testing.T) {
	versions := makeVersions(8, time.Now(), time.Hour)
	toDelete := FIFO(versions, 5)
	if len(toDelete) != 3 {
		t.Fatalf("expected 3 deletions, got %d", len(toDelete))
	}
	// Oldest versions should be deleted: Num 1, 2, 3.
	for i, v := range toDelete {
		wantNum := i + 1
		if v.Num != wantNum {
			t.Errorf("toDelete[%d].Num = %d, want %d", i, v.Num, wantNum)
		}
	}
}

func TestFIFO_OldestFirst(t *testing.T) {
	start := time.Date(2024, 1, 1, 0, 0, 0, 0, time.UTC)
	versions := makeVersions(6, start, 24*time.Hour)
	toDelete := FIFO(versions, 4)
	if len(toDelete) != 2 {
		t.Fatalf("expected 2 deletions, got %d", len(toDelete))
	}
	if toDelete[0].Num > toDelete[1].Num {
		t.Errorf("deletions not oldest first: got Num %d before %d", toDelete[0].Num, toDelete[1].Num)
	}
}

// --- Intelliversioning tests ---

func TestIntelliversioning_UnderLimit(t *testing.T) {
	versions := makeVersions(3, time.Now(), time.Hour)
	toDelete := Intelliversioning(versions, 5)
	if toDelete != nil {
		t.Errorf("expected nil (under limit), got %v", toDelete)
	}
}

func TestIntelliversioning_AtLimit(t *testing.T) {
	versions := makeVersions(5, time.Now(), time.Hour)
	toDelete := Intelliversioning(versions, 5)
	if toDelete != nil {
		t.Errorf("expected nil (at limit), got %v", toDelete)
	}
}

func TestIntelliversioning_ClusteredPreferred(t *testing.T) {
	// Versions 1-4 are spread out one day apart.
	// Versions 5-7 are clustered very close together (1 second apart).
	// Intelliversioning should prefer to remove the clustered ones.
	base := time.Date(2024, 1, 1, 0, 0, 0, 0, time.UTC)
	spread := []VersionInfo{
		{ID: "v1", Num: 1, CreatedAt: base},
		{ID: "v2", Num: 2, CreatedAt: base.Add(24 * time.Hour)},
		{ID: "v3", Num: 3, CreatedAt: base.Add(48 * time.Hour)},
		{ID: "v4", Num: 4, CreatedAt: base.Add(72 * time.Hour)},
		// Clustered near the end.
		{ID: "v5", Num: 5, CreatedAt: base.Add(73 * time.Hour)},
		{ID: "v6", Num: 6, CreatedAt: base.Add(73*time.Hour + time.Second)},
		{ID: "v7", Num: 7, CreatedAt: base.Add(73*time.Hour + 2*time.Second)},
	}

	toDelete := Intelliversioning(spread, 5)
	if len(toDelete) != 2 {
		t.Fatalf("expected 2 deletions, got %d: %v", len(toDelete), toDelete)
	}

	// The deleted versions should be from the clustered group (v5 or v6).
	deletedNums := map[int]bool{}
	for _, v := range toDelete {
		deletedNums[v.Num] = true
	}
	// v1 and v7 (first and last) must never be deleted.
	if deletedNums[1] {
		t.Error("first version (v1) was deleted — must never happen")
	}
	if deletedNums[7] {
		t.Error("last version (v7) was deleted — must never happen")
	}
	// The deleted ones should be among the clustered versions (v5/v6 are interior clustered).
	for num := range deletedNums {
		if num < 5 {
			t.Errorf("deleted spread version %d instead of clustered ones", num)
		}
	}
}

func TestIntelliversioning_NeverDeleteFirstOrLast(t *testing.T) {
	versions := makeVersions(10, time.Now(), time.Hour)
	first := versions[0]
	last := versions[len(versions)-1]

	toDelete := Intelliversioning(versions, 3)
	for _, v := range toDelete {
		if v.ID == first.ID {
			t.Error("Intelliversioning deleted the first version")
		}
		if v.ID == last.ID {
			t.Error("Intelliversioning deleted the last version")
		}
	}
}

func TestIntelliversioning_CorrectCount(t *testing.T) {
	versions := makeVersions(10, time.Now(), time.Hour)
	toDelete := Intelliversioning(versions, 4)
	if len(toDelete) != 6 {
		t.Errorf("expected 6 deletions, got %d", len(toDelete))
	}
}
