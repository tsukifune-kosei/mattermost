// Copyright (c) 2015-present Mattermost, Inc. All Rights Reserved.
// See LICENSE.txt for license information.

package model

import (
	"encoding/json"
	"io"
	"net/http"
)

// ChannelReadCursor represents a user's reading progress in a channel
type ChannelReadCursor struct {
	ChannelId   string `json:"channel_id"`
	UserId      string `json:"user_id"`
	LastPostSeq int64  `json:"last_post_seq"` // Sequence number (typically CreateAt timestamp)
	UpdatedAt   int64  `json:"updated_at"`
}

// ReadCursorAdvanceRequest is the request body for advancing a read cursor
type ReadCursorAdvanceRequest struct {
	LastPostSeq int64  `json:"last_post_seq,omitempty"` // Direct sequence number
	PostId      string `json:"post_id,omitempty"`       // Alternative: derive seq from post
}

// ReadCursorEvent is the event published to the read index service
type ReadCursorEvent struct {
	Type        string `json:"type"`
	EventId     string `json:"event_id"`
	ChannelId   string `json:"channel_id"`
	UserId      string `json:"user_id"`
	PrevLastSeq int64  `json:"prev_last_seq"`
	NewLastSeq  int64  `json:"new_last_seq"`
	Timestamp   int64  `json:"timestamp"`
}

// IsValid validates the ChannelReadCursor
func (c *ChannelReadCursor) IsValid() *AppError {
	if !IsValidId(c.ChannelId) {
		return NewAppError("ChannelReadCursor.IsValid", "model.channel_read_cursor.is_valid.channel_id.app_error", nil, "", http.StatusBadRequest)
	}

	if !IsValidId(c.UserId) {
		return NewAppError("ChannelReadCursor.IsValid", "model.channel_read_cursor.is_valid.user_id.app_error", nil, "", http.StatusBadRequest)
	}

	if c.LastPostSeq < 0 {
		return NewAppError("ChannelReadCursor.IsValid", "model.channel_read_cursor.is_valid.seq.app_error", nil, "", http.StatusBadRequest)
	}

	if c.UpdatedAt == 0 {
		return NewAppError("ChannelReadCursor.IsValid", "model.channel_read_cursor.is_valid.updated_at.app_error", nil, "", http.StatusBadRequest)
	}

	return nil
}

// PreSave will set default values and validate
func (c *ChannelReadCursor) PreSave() {
	if c.UpdatedAt == 0 {
		c.UpdatedAt = GetMillis()
	}
}

// ToJSON converts ChannelReadCursor to JSON
func (c *ChannelReadCursor) ToJSON() string {
	b, _ := json.Marshal(c)
	return string(b)
}

// ChannelReadCursorFromJSON decodes JSON to ChannelReadCursor
func ChannelReadCursorFromJSON(data io.Reader) *ChannelReadCursor {
	var c ChannelReadCursor
	if err := json.NewDecoder(data).Decode(&c); err != nil {
		return nil
	}
	return &c
}

// ToJSON converts ReadCursorAdvanceRequest to JSON
func (r *ReadCursorAdvanceRequest) ToJSON() string {
	b, _ := json.Marshal(r)
	return string(b)
}

// ReadCursorAdvanceRequestFromJSON decodes JSON to ReadCursorAdvanceRequest
func ReadCursorAdvanceRequestFromJSON(data io.Reader) *ReadCursorAdvanceRequest {
	var r ReadCursorAdvanceRequest
	if err := json.NewDecoder(data).Decode(&r); err != nil {
		return nil
	}
	return &r
}

// IsValid validates the ReadCursorAdvanceRequest
func (r *ReadCursorAdvanceRequest) IsValid() *AppError {
	if r.LastPostSeq == 0 && r.PostId == "" {
		return NewAppError("ReadCursorAdvanceRequest.IsValid", "model.read_cursor_advance_request.is_valid.empty.app_error", nil, "", http.StatusBadRequest)
	}

	if r.PostId != "" && !IsValidId(r.PostId) {
		return NewAppError("ReadCursorAdvanceRequest.IsValid", "model.read_cursor_advance_request.is_valid.post_id.app_error", nil, "", http.StatusBadRequest)
	}

	if r.LastPostSeq < 0 {
		return NewAppError("ReadCursorAdvanceRequest.IsValid", "model.read_cursor_advance_request.is_valid.seq.app_error", nil, "", http.StatusBadRequest)
	}

	return nil
}

// ToJSON converts ReadCursorEvent to JSON
func (e *ReadCursorEvent) ToJSON() string {
	b, _ := json.Marshal(e)
	return string(b)
}

// ReadCursorEventFromJSON decodes JSON to ReadCursorEvent
func ReadCursorEventFromJSON(data io.Reader) *ReadCursorEvent {
	var e ReadCursorEvent
	if err := json.NewDecoder(data).Decode(&e); err != nil {
		return nil
	}
	return &e
}
