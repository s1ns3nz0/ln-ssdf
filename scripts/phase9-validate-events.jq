# Input is slurped with jq -s. Output stays one validated record per line.
select(length == 3)
| select(all(.[]; type == "object" and (keys | sort) == ["amount_sat","correlation_id","endpoint","event","outcome","subject"]))
| select([.[].event] == ["challenge", "settlement", "authorized_access"])
| select([.[].outcome] == ["received", "settled", "authorized"])
| select(all(.[]; .subject == $expected_subject and .amount_sat == 10))
| select(all(.[]; (.endpoint | startswith("/v1/indicator/"))))
| select((map(.correlation_id) | unique) | length == 1)
| select(.[0].correlation_id | type == "string" and length > 0)
| .[]
