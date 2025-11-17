// Copyright (c) 2015-present Mattermost, Inc. All Rights Reserved.
// See LICENSE.txt for license information.

import React from 'react';
import {Modal} from 'react-bootstrap';
import {FormattedMessage} from 'react-intl';

import type {UserProfile} from '@mattermost/types/users';

import Avatar from 'components/widgets/users/avatar';
import LoadingScreen from 'components/loading_screen';

import './post_read_receipts_modal.scss';

type Props = {
    postId: string;
    channelId: string;
    readers: UserProfile[];
    totalCount: number;
    isLoading: boolean;
    onHide: () => void;
    show: boolean;
};

export default class PostReadReceiptsModal extends React.PureComponent<Props> {
    render() {
        const {show, onHide, readers, totalCount, isLoading} = this.props;

        return (
            <Modal
                dialogClassName='post-read-receipts-modal'
                show={show}
                onHide={onHide}
                backdrop='static'
                role='dialog'
                aria-labelledby='postReadReceiptsModalLabel'
            >
                <Modal.Header closeButton={true}>
                    <Modal.Title
                        componentClass='h1'
                        id='postReadReceiptsModalLabel'
                    >
                        <FormattedMessage
                            id='post.read_receipts.modal.title'
                            defaultMessage='Read by {count, number} {count, plural, one {person} other {people}}'
                            values={{count: totalCount}}
                        />
                    </Modal.Title>
                </Modal.Header>
                <Modal.Body>
                    {isLoading ? (
                        <LoadingScreen/>
                    ) : (
                        <div className='read-receipts-list'>
                            {readers.length === 0 ? (
                                <div className='no-readers'>
                                    <FormattedMessage
                                        id='post.read_receipts.modal.no_readers'
                                        defaultMessage='No one has read this message yet'
                                    />
                                </div>
                            ) : (
                                readers.map((user) => (
                                    <div
                                        key={user.id}
                                        className='read-receipt-item'
                                    >
                                        <Avatar
                                            username={user.username}
                                            size='md'
                                            url={`/api/v4/users/${user.id}/image`}
                                        />
                                        <div className='user-info'>
                                            <div className='user-name'>
                                                {user.first_name && user.last_name ? (
                                                    <span>{`${user.first_name} ${user.last_name}`}</span>
                                                ) : (
                                                    <span>{user.username}</span>
                                                )}
                                            </div>
                                            <div className='user-username'>
                                                @{user.username}
                                            </div>
                                        </div>
                                    </div>
                                ))
                            )}
                            {readers.length < totalCount && (
                                <div className='more-readers'>
                                    <FormattedMessage
                                        id='post.read_receipts.modal.more'
                                        defaultMessage='and {count} more...'
                                        values={{count: totalCount - readers.length}}
                                    />
                                </div>
                            )}
                        </div>
                    )}
                </Modal.Body>
            </Modal>
        );
    }
}
