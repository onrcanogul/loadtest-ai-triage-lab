package com.lab.scoring.service;

import com.lab.scoring.config.FailureModes;
import org.junit.jupiter.api.Test;

import static org.assertj.core.api.Assertions.assertThat;

class ScoringServiceTest {

    @Test
    void scoreIsDeterministicAndWithinRange() {
        ScoringService service = new ScoringService(new FailureModes(false));

        int first = service.score("C123456");
        int second = service.score("C123456");

        assertThat(first).isEqualTo(second).isBetween(300, 900);
    }
}
