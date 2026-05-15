Found a bug:
Background: Member B owes Member A 300, Member C owes Member A 300. 

Scenario: Add expense, choose member B as paid member. split with 5 members (A,B,C,D,E). Total amount = 200.
Expected: In Expense summary, 
- Member B owes amount deducted from 100 to 60
- Member C owes Member B 40
- Member D owes Member B 40 
- Member E owes Member B 40

Actual Result: In summary, 
- Member B owes amount deducted from 300 to 100 
- Member C owes Member A 340
- Member D owes Member A 40
- Member E owes Member A 40

Here i see it centralized to Member A. But it's confusing and I don't think we had introduce the "Central member" in past conversation. 

Make it work as my expectation.