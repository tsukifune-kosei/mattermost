// Copyright (c) 2015-present Mattermost, Inc. All Rights Reserved.
// See LICENSE.txt for license information.

import React from 'react';
import {FormattedMessage} from 'react-intl';

import './post_read_indicator.scss';

type Props = {
    postId: string;
    readCount?: number;
    onClick?: () => void;
    actions?: {
        fetchReadReceiptsCount: (postId: string) => void;
    };
};

export default class PostReadIndicator extends React.PureComponent<Props> {
    componentDidMount() {
        // Fetch read receipts count when component mounts
        if (this.props.actions?.fetchReadReceiptsCount) {
            this.props.actions.fetchReadReceiptsCount(this.props.postId);
        }
    }

    render() {
        const {readCount = 0, onClick} = this.props;

        // Don't show if no one has read
        if (readCount === 0) {
            return null;
        }

        return (
            <button
                className='post-read-indicator'
                onClick={onClick}
                aria-label={`${readCount} ${readCount === 1 ? 'person has' : 'people have'} read this message`}
                title={`${readCount} ${readCount === 1 ? 'person has' : 'people have'} read this message`}
            >
                <span className='read-count'>
                    {readCount === 1 ? '1 read' : `${readCount} read`}
                </span>
            </button>
        );
    }
}
