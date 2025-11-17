// Copyright (c) 2015-present Mattermost, Inc. All Rights Reserved.
// See LICENSE.txt for license information.

package model

import (
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestChannelReadCursorIsValid(t *testing.T) {
	t.Run("valid cursor", func(t *testing.T) {
		cursor := &ChannelReadCursor{
			ChannelId:   NewId(),
			UserId:      NewId(),
			LastPostSeq: 1234567890000,
			UpdatedAt:   GetMillis(),
		}
		assert.Nil(t, cursor.IsValid())
	})

	t.Run("invalid channel id", func(t *testing.T) {
		cursor := &ChannelReadCursor{
			ChannelId:   "invalid",
			UserId:      NewId(),
			LastPostSeq: 1234567890000,
			UpdatedAt:   GetMillis(),
		}
		assert.NotNil(t, cursor.IsValid())
	})

	t.Run("invalid user id", func(t *testing.T) {
		cursor := &ChannelReadCursor{
			ChannelId:   NewId(),
			UserId:      "invalid",
			LastPostSeq: 1234567890000,
			UpdatedAt:   GetMillis(),
		}
		assert.NotNil(t, cursor.IsValid())
	})

	t.Run("negative sequence", func(t *testing.T) {
		cursor := &ChannelReadCursor{
			ChannelId:   NewId(),
			UserId:      NewId(),
			LastPostSeq: -1,
			UpdatedAt:   GetMillis(),
		}
		assert.NotNil(t, cursor.IsValid())
	})

	t.Run("zero updated_at", func(t *testing.T) {
		cursor := &ChannelReadCursor{
			ChannelId:   NewId(),
			UserId:      NewId(),
			LastPostSeq: 1234567890000,
			UpdatedAt:   0,
		}
		assert.NotNil(t, cursor.IsValid())
	})
}

func TestChannelReadCursorPreSave(t *testing.T) {
	cursor := &ChannelReadCursor{
		ChannelId:   NewId(),
		UserId:      NewId(),
		LastPostSeq: 1234567890000,
	}

	cursor.PreSave()
	assert.NotZero(t, cursor.UpdatedAt)
}

func TestChannelReadCursorJSON(t *testing.T) {
	cursor := &ChannelReadCursor{
		ChannelId:   NewId(),
		UserId:      NewId(),
		LastPostSeq: 1234567890000,
		UpdatedAt:   GetMillis(),
	}

	json := cursor.ToJSON()
	assert.NotEmpty(t, json)

	decoded := ChannelReadCursorFromJSON(strings.NewReader(json))
	require.NotNil(t, decoded)
	assert.Equal(t, cursor.ChannelId, decoded.ChannelId)
	assert.Equal(t, cursor.UserId, decoded.UserId)
	assert.Equal(t, cursor.LastPostSeq, decoded.LastPostSeq)
	assert.Equal(t, cursor.UpdatedAt, decoded.UpdatedAt)
}

func TestReadCursorAdvanceRequestIsValid(t *testing.T) {
	t.Run("valid with seq", func(t *testing.T) {
		req := &ReadCursorAdvanceRequest{
			LastPostSeq: 1234567890000,
		}
		assert.Nil(t, req.IsValid())
	})

	t.Run("valid with post_id", func(t *testing.T) {
		req := &ReadCursorAdvanceRequest{
			PostId: NewId(),
		}
		assert.Nil(t, req.IsValid())
	})

	t.Run("empty request", func(t *testing.T) {
		req := &ReadCursorAdvanceRequest{}
		assert.NotNil(t, req.IsValid())
	})

	t.Run("invalid post_id", func(t *testing.T) {
		req := &ReadCursorAdvanceRequest{
			PostId: "invalid",
		}
		assert.NotNil(t, req.IsValid())
	})

	t.Run("negative seq", func(t *testing.T) {
		req := &ReadCursorAdvanceRequest{
			LastPostSeq: -1,
		}
		assert.NotNil(t, req.IsValid())
	})
}

func TestReadCursorAdvanceRequestJSON(t *testing.T) {
	req := &ReadCursorAdvanceRequest{
		LastPostSeq: 1234567890000,
		PostId:      NewId(),
	}

	json := req.ToJSON()
	assert.NotEmpty(t, json)

	decoded := ReadCursorAdvanceRequestFromJSON(strings.NewReader(json))
	require.NotNil(t, decoded)
	assert.Equal(t, req.LastPostSeq, decoded.LastPostSeq)
	assert.Equal(t, req.PostId, decoded.PostId)
}

func TestReadCursorEventJSON(t *testing.T) {
	event := &ReadCursorEvent{
		Type:        "channel_read_advanced",
		EventId:     NewId(),
		ChannelId:   NewId(),
		UserId:      NewId(),
		PrevLastSeq: 1234567890000,
		NewLastSeq:  1234567895000,
		Timestamp:   GetMillis(),
	}

	json := event.ToJSON()
	assert.NotEmpty(t, json)

	decoded := ReadCursorEventFromJSON(strings.NewReader(json))
	require.NotNil(t, decoded)
	assert.Equal(t, event.Type, decoded.Type)
	assert.Equal(t, event.EventId, decoded.EventId)
	assert.Equal(t, event.ChannelId, decoded.ChannelId)
	assert.Equal(t, event.UserId, decoded.UserId)
	assert.Equal(t, event.PrevLastSeq, decoded.PrevLastSeq)
	assert.Equal(t, event.NewLastSeq, decoded.NewLastSeq)
	assert.Equal(t, event.Timestamp, decoded.Timestamp)
}
