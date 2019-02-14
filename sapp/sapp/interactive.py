#!/usr/bin/env python3

import IPython
from sapp.db import DB
from sapp.models import Issue, IssueInstance, SourceLocation
from sqlalchemy.orm import joinedload


class Interactive:
    help_message = """
issues()        list all issues
help()          show this message
    """
    welcome_message = "Interactive issue exploration. Type 'help()' for help."

    def __init__(self, database, database_name):
        self.db = DB(database, database_name, assertions=True)
        self.scope_vars = {"help": self.help, "issues": self.issues}

    def start_repl(self):
        print("=" * len(self.welcome_message))
        print(self.welcome_message)
        print("=" * len(self.welcome_message))
        IPython.start_ipython(argv=[], user_ns=self.scope_vars)

    def help(self):
        print(self.help_message)

    def issues(self):
        with self.db.make_session() as session:
            issues = (
                session.query(IssueInstance, Issue)
                .join(Issue, IssueInstance.issue_id == Issue.id)
                .options(joinedload(IssueInstance.message))
                .all()
            )

        for issue_instance, issue in issues:
            print(f"Issue {issue_instance.id}")
            print(f"    Code: {issue.code}")
            print(f" Message: {issue_instance.message.contents}")
            print(f"Callable: {issue.callable}")
            print(
                f"Location: {issue_instance.filename}"
                f":{SourceLocation.to_string(issue_instance.location)}"
            )
            print("-" * 80)
