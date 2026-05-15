# Owing Summary Feedback

1. It is a bit hard to read when all is just text. Make the user tag here, and use UI instead of "owes" text to mention the owing relationship.
2. When clicking on a particular user, highlight the amount text at the right side instead of after the user tag. Use green for being owed and yellow for owing.
   - Member C owes Member A 100 -> show Member C tag and use green to highlight the amount.
   - Member A owes Member B 50 -> show Member B tag and use yellow to highlight the amount.
3. With the Owing summary, the `(paid xxx)` beside totals is not useful. Remove it.
4. In Owing summary, show the total, like how much underpaid or how much is owed.
5. In all Owing summary, use color as well and group by member.

Add feature:

- When clicking on the user tag in Owing summary, filter the related expenses and show them. Clicking again will show the all summary.

Latest feedback:

- The Owing summary for all members is too long on first review. Collapse it when first entering the page, and let the user expand or collapse it.
- Remove the `+` and `-` symbols before amounts.
- Move the `To receive` and `To pay` summary totals to the bottom-right of each member group.
- Split each member's Owing summary into two sections so it is easier to scan: show `To receive` first, then `To pay`. The all-member summary should use the same section behavior.
- In the all-member Owing summary, center each member tag above that member's section, while keeping the receive/pay summary layout below it.
