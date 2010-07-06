#!/usr/bin/perl -w
#
# The contents of this file are subject to the Mozilla Public
# License Version 1.1 (the "License"); you may not use this file
# except in compliance with the License. You may obtain a copy of
# the License at http://www.mozilla.org/MPL/
#
# Software distributed under the License is distributed on an "AS
# IS" basis, WITHOUT WARRANTY OF ANY KIND, either express or
# implied. See the License for the specific language governing
# rights and limitations under the License.
#
# The Original Code is the Bugzilla Bug Tracking System.
#
# The Initial Developer of the Original Code is Everything Solved, Inc.
# Portions created by the Initial Developer are Copyright (C) 2009 the
# Initial Developer. All Rights Reserved.
#
# Contributor(s):
#   Max Kanat-Alexander <mkanat@bugzilla.org>

use strict;
use warnings;
use lib qw(. lib);

use Bugzilla;
use Bugzilla::Config qw(:admin);
use Bugzilla::Status;

my $confirmed   = new Bugzilla::Status({ name => 'CONFIRMED' });
my $in_progress = new Bugzilla::Status({ name => 'IN_PROGRESS' });

if ($confirmed and $in_progress) {
    print "You are already using the new workflow.\n";
    exit 1;
}

print <<END;
WARNING: This will convert the status of all bugs using the following
system:

  "NEW" will become "CONFIRMED"
  "ASSIGNED" will become "IN_PROGRESS"
  "REOPENED" will become "CONFIRMED" (and the "REOPENED" status will be removed)
  "CLOSED" will become "VERIFIED" (and the "CLOSED" status will be removed)

This change will be immediate. The history of each bug will also be changed
so that it appears that these statuses were always in existence.

Emails will not be sent for the change.

To continue, press any key, or press Ctrl-C to stop this program...
END
getc;

my $dbh = Bugzilla->dbh;
my %translation = (
    NEW      => 'CONFIRMED',
    ASSIGNED => 'IN_PROGRESS',
    REOPENED => 'CONFIRMED',
    CLOSED   => 'VERIFIED',
);

my $status_field = Bugzilla::Field->check('bug_status');
$dbh->bz_start_transaction();
while (my ($from, $to) = each %translation) {
    print "Converting $from to $to...\n";
    $dbh->do('UPDATE bugs SET bug_status = ? WHERE bug_status = ?',
             undef, $to, $from);

    if (Bugzilla->params->{'duplicate_or_move_bug_status'} eq $from) {
        SetParam('duplicate_or_move_bug_status', $to);
        write_params();
    }

    foreach my $what (qw(added removed)) {
        $dbh->do("UPDATE bugs_activity SET $what = ? 
                   WHERE fieldid = ? AND $what = ?",
                 undef, $to, $status_field->id, $from);
    }

    # Delete any transitions where it now appears that
    # a bug moved from a status to itself.
    $dbh->do('DELETE FROM bugs_activity WHERE fieldid = ? AND added = removed',
             undef, $status_field->id);

    # If the new status already exists, just delete the old one, but retain
    # the workflow items from it.
    if (my $existing = new Bugzilla::Status({ name => $to })) {
        $dbh->do('DELETE FROM bug_status WHERE value = ?', undef, $from);
    }
    # Otherwise, rename the old status to the new one.
    else {
        $dbh->do('UPDATE bug_status SET value = ? WHERE value = ?',
                 undef, $to, $from);
    }
}

$dbh->bz_commit_transaction();

print <<END;
Done. There are some things you may want to fix, now:

  * You may want to run ./collectstats.pl --regenerate to regenerate
    data for the Old Charts system. 
  * You may have to fix the Status Workflow using the Status Workflow
    panel in "Administration".
  * You will probably want to update the "mybugstemplate" and "defaultquery"
    parameters using the Parameters panel in "Administration". (Just
    resetting them to the default will work.)
END